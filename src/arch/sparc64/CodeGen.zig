//! SPARCv9 codegen.
//! This lowers AIR into MIR.
//! For now this only implements medium/low code model with absolute addressing.
//! TODO add support for other code models.
const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.codegen);
const math = std.math;
const mem = std.mem;
const Allocator = mem.Allocator;
const builtin = @import("builtin");
const link = @import("../../link.zig");
const Module = @import("../../Module.zig");
const TypedValue = @import("../../TypedValue.zig");
const ErrorMsg = Module.ErrorMsg;
const Air = @import("../../Air.zig");
const Mir = @import("Mir.zig");
const Emit = @import("Emit.zig");
const Liveness = @import("../../Liveness.zig");
const Type = @import("../../type.zig").Type;
const GenerateSymbolError = @import("../../codegen.zig").GenerateSymbolError;
const FnResult = @import("../../codegen.zig").FnResult;
const DebugInfoOutput = @import("../../codegen.zig").DebugInfoOutput;

const build_options = @import("build_options");

const bits = @import("bits.zig");
const abi = @import("abi.zig");
const Instruction = bits.Instruction;
const ShiftWidth = Instruction.ShiftWidth;
const RegisterManager = abi.RegisterManager;
const RegisterLock = RegisterManager.RegisterLock;
const Register = bits.Register;
const gp = abi.RegisterClass.gp;

const Self = @This();

const InnerError = error{
    OutOfMemory,
    CodegenFail,
    OutOfRegisters,
};

const RegisterView = enum(u1) {
    caller,
    callee,
};

gpa: Allocator,
air: Air,
liveness: Liveness,
bin_file: *link.File,
target: *const std.Target,
mod_fn: *const Module.Fn,
code: *std.ArrayList(u8),
debug_output: DebugInfoOutput,
err_msg: ?*ErrorMsg,
args: []MCValue,
ret_mcv: MCValue,
fn_type: Type,
arg_index: usize,
src_loc: Module.SrcLoc,
stack_align: u32,

/// MIR Instructions
mir_instructions: std.MultiArrayList(Mir.Inst) = .{},
/// MIR extra data
mir_extra: std.ArrayListUnmanaged(u32) = .{},

/// Byte offset within the source file of the ending curly.
end_di_line: u32,
end_di_column: u32,

/// The value is an offset into the `Function` `code` from the beginning.
/// To perform the reloc, write 32-bit signed little-endian integer
/// which is a relative jump, based on the address following the reloc.
exitlude_jump_relocs: std.ArrayListUnmanaged(usize) = .{},

/// Whenever there is a runtime branch, we push a Branch onto this stack,
/// and pop it off when the runtime branch joins. This provides an "overlay"
/// of the table of mappings from instructions to `MCValue` from within the branch.
/// This way we can modify the `MCValue` for an instruction in different ways
/// within different branches. Special consideration is needed when a branch
/// joins with its parent, to make sure all instructions have the same MCValue
/// across each runtime branch upon joining.
branch_stack: *std.ArrayList(Branch),

// Key is the block instruction
blocks: std.AutoHashMapUnmanaged(Air.Inst.Index, BlockData) = .{},

register_manager: RegisterManager = .{},

/// Maps offset to what is stored there.
stack: std.AutoHashMapUnmanaged(u32, StackAllocation) = .{},

/// Tracks the current instruction allocated to the compare flags
compare_flags_inst: ?Air.Inst.Index = null,

/// Offset from the stack base, representing the end of the stack frame.
max_end_stack: u32 = 0,
/// Represents the current end stack offset. If there is no existing slot
/// to place a new stack allocation, it goes here, and then bumps `max_end_stack`.
next_stack_offset: u32 = 0,

/// Debug field, used to find bugs in the compiler.
air_bookkeeping: @TypeOf(air_bookkeeping_init) = air_bookkeeping_init,

const air_bookkeeping_init = if (std.debug.runtime_safety) @as(usize, 0) else {};

const MCValue = union(enum) {
    /// No runtime bits. `void` types, empty structs, u0, enums with 1 tag, etc.
    /// TODO Look into deleting this tag and using `dead` instead, since every use
    /// of MCValue.none should be instead looking at the type and noticing it is 0 bits.
    none,
    /// Control flow will not allow this value to be observed.
    unreach,
    /// No more references to this value remain.
    dead,
    /// The value is undefined.
    undef,
    /// A pointer-sized integer that fits in a register.
    /// If the type is a pointer, this is the pointer address in virtual address space.
    immediate: u64,
    /// The value is in a target-specific register.
    register: Register,
    /// The value is in memory at a hard-coded address.
    /// If the type is a pointer, it means the pointer address is at this memory location.
    memory: u64,
    /// The value is one of the stack variables.
    /// If the type is a pointer, it means the pointer address is in the stack at this offset.
    stack_offset: u32,
    /// The value is a pointer to one of the stack variables (payload is stack offset).
    ptr_stack_offset: u32,
    /// The value is in the specified CCR assuming an unsigned operation,
    /// with the operator applied on top of it.
    compare_flags_unsigned: struct {
        cmp: math.CompareOperator,
        ccr: Instruction.CCR,
    },
    /// The value is in the specified CCR assuming an signed operation,
    /// with the operator applied on top of it.
    compare_flags_signed: struct {
        cmp: math.CompareOperator,
        ccr: Instruction.CCR,
    },

    fn isMemory(mcv: MCValue) bool {
        return switch (mcv) {
            .memory, .stack_offset => true,
            else => false,
        };
    }

    fn isImmediate(mcv: MCValue) bool {
        return switch (mcv) {
            .immediate => true,
            else => false,
        };
    }

    fn isMutable(mcv: MCValue) bool {
        return switch (mcv) {
            .none => unreachable,
            .unreach => unreachable,
            .dead => unreachable,

            .immediate,
            .memory,
            .ptr_stack_offset,
            .undef,
            => false,

            .register,
            .stack_offset,
            => true,
        };
    }
};

const Branch = struct {
    inst_table: std.AutoArrayHashMapUnmanaged(Air.Inst.Index, MCValue) = .{},

    fn deinit(self: *Branch, gpa: Allocator) void {
        self.inst_table.deinit(gpa);
        self.* = undefined;
    }
};

const StackAllocation = struct {
    inst: Air.Inst.Index,
    /// TODO do we need size? should be determined by inst.ty.abiSize()
    size: u32,
};

const BlockData = struct {
    relocs: std.ArrayListUnmanaged(Mir.Inst.Index),
    /// The first break instruction encounters `null` here and chooses a
    /// machine code value for the block result, populating this field.
    /// Following break instructions encounter that value and use it for
    /// the location to store their block results.
    mcv: MCValue,
};

const CallMCValues = struct {
    args: []MCValue,
    return_value: MCValue,
    stack_byte_count: u32,
    stack_align: u32,

    fn deinit(self: *CallMCValues, func: *Self) void {
        func.gpa.free(self.args);
        self.* = undefined;
    }
};

const BigTomb = struct {
    function: *Self,
    inst: Air.Inst.Index,
    tomb_bits: Liveness.Bpi,
    big_tomb_bits: u32,
    bit_index: usize,

    fn feed(bt: *BigTomb, op_ref: Air.Inst.Ref) void {
        const this_bit_index = bt.bit_index;
        bt.bit_index += 1;

        const op_int = @enumToInt(op_ref);
        if (op_int < Air.Inst.Ref.typed_value_map.len) return;
        const op_index = @intCast(Air.Inst.Index, op_int - Air.Inst.Ref.typed_value_map.len);

        if (this_bit_index < Liveness.bpi - 1) {
            const dies = @truncate(u1, bt.tomb_bits >> @intCast(Liveness.OperandInt, this_bit_index)) != 0;
            if (!dies) return;
        } else {
            const big_bit_index = @intCast(u5, this_bit_index - (Liveness.bpi - 1));
            const dies = @truncate(u1, bt.big_tomb_bits >> big_bit_index) != 0;
            if (!dies) return;
        }
        bt.function.processDeath(op_index);
    }

    fn finishAir(bt: *BigTomb, result: MCValue) void {
        const is_used = !bt.function.liveness.isUnused(bt.inst);
        if (is_used) {
            log.debug("%{d} => {}", .{ bt.inst, result });
            const branch = &bt.function.branch_stack.items[bt.function.branch_stack.items.len - 1];
            branch.inst_table.putAssumeCapacityNoClobber(bt.inst, result);
        }
        bt.function.finishAirBookkeeping();
    }
};

pub fn generate(
    bin_file: *link.File,
    src_loc: Module.SrcLoc,
    module_fn: *Module.Fn,
    air: Air,
    liveness: Liveness,
    code: *std.ArrayList(u8),
    debug_output: DebugInfoOutput,
) GenerateSymbolError!FnResult {
    if (build_options.skip_non_native and builtin.cpu.arch != bin_file.options.target.cpu.arch) {
        @panic("Attempted to compile for architecture that was disabled by build configuration");
    }

    const mod = bin_file.options.module.?;
    const fn_owner_decl = mod.declPtr(module_fn.owner_decl);
    assert(fn_owner_decl.has_tv);
    const fn_type = fn_owner_decl.ty;

    var branch_stack = std.ArrayList(Branch).init(bin_file.allocator);
    defer {
        assert(branch_stack.items.len == 1);
        branch_stack.items[0].deinit(bin_file.allocator);
        branch_stack.deinit();
    }
    try branch_stack.append(.{});

    var function = Self{
        .gpa = bin_file.allocator,
        .air = air,
        .liveness = liveness,
        .target = &bin_file.options.target,
        .bin_file = bin_file,
        .mod_fn = module_fn,
        .code = code,
        .debug_output = debug_output,
        .err_msg = null,
        .args = undefined, // populated after `resolveCallingConventionValues`
        .ret_mcv = undefined, // populated after `resolveCallingConventionValues`
        .fn_type = fn_type,
        .arg_index = 0,
        .branch_stack = &branch_stack,
        .src_loc = src_loc,
        .stack_align = undefined,
        .end_di_line = module_fn.rbrace_line,
        .end_di_column = module_fn.rbrace_column,
    };
    defer function.stack.deinit(bin_file.allocator);
    defer function.blocks.deinit(bin_file.allocator);
    defer function.exitlude_jump_relocs.deinit(bin_file.allocator);

    var call_info = function.resolveCallingConventionValues(fn_type, .callee) catch |err| switch (err) {
        error.CodegenFail => return FnResult{ .fail = function.err_msg.? },
        error.OutOfRegisters => return FnResult{
            .fail = try ErrorMsg.create(bin_file.allocator, src_loc, "CodeGen ran out of registers. This is a bug in the Zig compiler.", .{}),
        },
        else => |e| return e,
    };
    defer call_info.deinit(&function);

    function.args = call_info.args;
    function.ret_mcv = call_info.return_value;
    function.stack_align = call_info.stack_align;
    function.max_end_stack = call_info.stack_byte_count;

    function.gen() catch |err| switch (err) {
        error.CodegenFail => return FnResult{ .fail = function.err_msg.? },
        error.OutOfRegisters => return FnResult{
            .fail = try ErrorMsg.create(bin_file.allocator, src_loc, "CodeGen ran out of registers. This is a bug in the Zig compiler.", .{}),
        },
        else => |e| return e,
    };

    var mir = Mir{
        .instructions = function.mir_instructions.toOwnedSlice(),
        .extra = function.mir_extra.toOwnedSlice(bin_file.allocator),
    };
    defer mir.deinit(bin_file.allocator);

    var emit = Emit{
        .mir = mir,
        .bin_file = bin_file,
        .debug_output = debug_output,
        .target = &bin_file.options.target,
        .src_loc = src_loc,
        .code = code,
        .prev_di_pc = 0,
        .prev_di_line = module_fn.lbrace_line,
        .prev_di_column = module_fn.lbrace_column,
    };
    defer emit.deinit();

    emit.emitMir() catch |err| switch (err) {
        error.EmitFail => return FnResult{ .fail = emit.err_msg.? },
        else => |e| return e,
    };

    if (function.err_msg) |em| {
        return FnResult{ .fail = em };
    } else {
        return FnResult{ .appended = {} };
    }
}

fn gen(self: *Self) !void {
    const cc = self.fn_type.fnCallingConvention();
    if (cc != .Naked) {
        // TODO Finish function prologue and epilogue for sparc64.

        // save %sp, stack_reserved_area, %sp
        const save_inst = try self.addInst(.{
            .tag = .save,
            .data = .{
                .arithmetic_3op = .{
                    .is_imm = true,
                    .rd = .sp,
                    .rs1 = .sp,
                    .rs2_or_imm = .{ .imm = -abi.stack_reserved_area },
                },
            },
        });

        _ = try self.addInst(.{
            .tag = .dbg_prologue_end,
            .data = .{ .nop = {} },
        });

        try self.genBody(self.air.getMainBody());

        _ = try self.addInst(.{
            .tag = .dbg_epilogue_begin,
            .data = .{ .nop = {} },
        });

        // exitlude jumps
        if (self.exitlude_jump_relocs.items.len > 0 and
            self.exitlude_jump_relocs.items[self.exitlude_jump_relocs.items.len - 1] == self.mir_instructions.len - 3)
        {
            // If the last Mir instruction (apart from the
            // dbg_epilogue_begin) is the last exitlude jump
            // relocation (which would just jump two instructions
            // further), it can be safely removed
            const index = self.exitlude_jump_relocs.pop();

            // First, remove the delay slot, then remove
            // the branch instruction itself.
            self.mir_instructions.orderedRemove(index + 1);
            self.mir_instructions.orderedRemove(index);
        }

        for (self.exitlude_jump_relocs.items) |jmp_reloc| {
            self.mir_instructions.set(jmp_reloc, .{
                .tag = .bpcc,
                .data = .{
                    .branch_predict_int = .{
                        .ccr = .xcc,
                        .cond = .al,
                        .inst = @intCast(u32, self.mir_instructions.len),
                    },
                },
            });
        }

        // Backpatch stack offset
        const total_stack_size = self.max_end_stack + abi.stack_reserved_area;
        const stack_size = mem.alignForwardGeneric(u32, total_stack_size, self.stack_align);
        if (math.cast(i13, stack_size)) |size| {
            self.mir_instructions.set(save_inst, .{
                .tag = .save,
                .data = .{
                    .arithmetic_3op = .{
                        .is_imm = true,
                        .rd = .sp,
                        .rs1 = .sp,
                        .rs2_or_imm = .{ .imm = -size },
                    },
                },
            });
        } else {
            // TODO for large stacks, replace the prologue with:
            // setx stack_size, %g1
            // save %sp, %g1, %sp
            return self.fail("TODO SPARCv9: allow larger stacks", .{});
        }

        // return %i7 + 8
        _ = try self.addInst(.{
            .tag = .@"return",
            .data = .{
                .arithmetic_2op = .{
                    .is_imm = true,
                    .rs1 = .@"i7",
                    .rs2_or_imm = .{ .imm = 8 },
                },
            },
        });

        // Branches in SPARC have a delay slot, that is, the instruction
        // following it will unconditionally be executed.
        // See: Section 3.2.3 Control Transfer in SPARCv9 manual.
        // See also: https://arcb.csc.ncsu.edu/~mueller/codeopt/codeopt00/notes/delaybra.html
        // TODO Find a way to fill this delay slot
        // nop
        _ = try self.addInst(.{
            .tag = .nop,
            .data = .{ .nop = {} },
        });
    } else {
        _ = try self.addInst(.{
            .tag = .dbg_prologue_end,
            .data = .{ .nop = {} },
        });

        try self.genBody(self.air.getMainBody());

        _ = try self.addInst(.{
            .tag = .dbg_epilogue_begin,
            .data = .{ .nop = {} },
        });
    }

    // Drop them off at the rbrace.
    _ = try self.addInst(.{
        .tag = .dbg_line,
        .data = .{ .dbg_line_column = .{
            .line = self.end_di_line,
            .column = self.end_di_column,
        } },
    });
}

fn genBody(self: *Self, body: []const Air.Inst.Index) InnerError!void {
    const air_tags = self.air.instructions.items(.tag);

    for (body) |inst| {
        const old_air_bookkeeping = self.air_bookkeeping;
        try self.ensureProcessDeathCapacity(Liveness.bpi);

        switch (air_tags[inst]) {
            // zig fmt: off
            .ptr_add => try self.airPtrArithmetic(inst, .ptr_add),
            .ptr_sub => try self.airPtrArithmetic(inst, .ptr_sub),

            .add             => try self.airBinOp(inst, .add),
            .addwrap         => @panic("TODO try self.airAddWrap(inst)"),
            .add_sat         => @panic("TODO try self.airAddSat(inst)"),
            .sub             => @panic("TODO try self.airBinOp(inst)"),
            .subwrap         => @panic("TODO try self.airSubWrap(inst)"),
            .sub_sat         => @panic("TODO try self.airSubSat(inst)"),
            .mul             => @panic("TODO try self.airMul(inst)"),
            .mulwrap         => @panic("TODO try self.airMulWrap(inst)"),
            .mul_sat         => @panic("TODO try self.airMulSat(inst)"),
            .rem             => @panic("TODO try self.airRem(inst)"),
            .mod             => @panic("TODO try self.airMod(inst)"),
            .shl, .shl_exact => @panic("TODO try self.airShl(inst)"),
            .shl_sat         => @panic("TODO try self.airShlSat(inst)"),
            .min             => @panic("TODO try self.airMin(inst)"),
            .max             => @panic("TODO try self.airMax(inst)"),
            .slice           => @panic("TODO try self.airSlice(inst)"),

            .sqrt,
            .sin,
            .cos,
            .tan,
            .exp,
            .exp2,
            .log,
            .log2,
            .log10,
            .fabs,
            .floor,
            .ceil,
            .round,
            .trunc_float,
            => @panic("TODO try self.airUnaryMath(inst)"),

            .add_with_overflow => @panic("TODO try self.airAddWithOverflow(inst)"),
            .sub_with_overflow => @panic("TODO try self.airSubWithOverflow(inst)"),
            .mul_with_overflow => @panic("TODO try self.airMulWithOverflow(inst)"),
            .shl_with_overflow => @panic("TODO try self.airShlWithOverflow(inst)"),

            .div_float, .div_trunc, .div_floor, .div_exact => try self.airDiv(inst),

            .cmp_lt  => try self.airCmp(inst, .lt),
            .cmp_lte => try self.airCmp(inst, .lte),
            .cmp_eq  => try self.airCmp(inst, .eq),
            .cmp_gte => try self.airCmp(inst, .gte),
            .cmp_gt  => try self.airCmp(inst, .gt),
            .cmp_neq => try self.airCmp(inst, .neq),
            .cmp_vector => @panic("TODO try self.airCmpVector(inst)"),
            .cmp_lt_errors_len => @panic("TODO try self.airCmpLtErrorsLen(inst)"),

            .bool_and        => @panic("TODO try self.airBoolOp(inst)"),
            .bool_or         => @panic("TODO try self.airBoolOp(inst)"),
            .bit_and         => @panic("TODO try self.airBitAnd(inst)"),
            .bit_or          => @panic("TODO try self.airBitOr(inst)"),
            .xor             => @panic("TODO try self.airXor(inst)"),
            .shr, .shr_exact => @panic("TODO try self.airShr(inst)"),

            .alloc           => try self.airAlloc(inst),
            .ret_ptr         => try self.airRetPtr(inst),
            .arg             => try self.airArg(inst),
            .assembly        => try self.airAsm(inst),
            .bitcast         => try self.airBitCast(inst),
            .block           => try self.airBlock(inst),
            .br              => try self.airBr(inst),
            .breakpoint      => try self.airBreakpoint(),
            .ret_addr        => @panic("TODO try self.airRetAddr(inst)"),
            .frame_addr      => @panic("TODO try self.airFrameAddress(inst)"),
            .fence           => @panic("TODO try self.airFence()"),
            .cond_br         => try self.airCondBr(inst),
            .dbg_stmt        => try self.airDbgStmt(inst),
            .fptrunc         => @panic("TODO try self.airFptrunc(inst)"),
            .fpext           => @panic("TODO try self.airFpext(inst)"),
            .intcast         => @panic("TODO try self.airIntCast(inst)"),
            .trunc           => @panic("TODO try self.airTrunc(inst)"),
            .bool_to_int     => @panic("TODO try self.airBoolToInt(inst)"),
            .is_non_null     => @panic("TODO try self.airIsNonNull(inst)"),
            .is_non_null_ptr => @panic("TODO try self.airIsNonNullPtr(inst)"),
            .is_null         => @panic("TODO try self.airIsNull(inst)"),
            .is_null_ptr     => @panic("TODO try self.airIsNullPtr(inst)"),
            .is_non_err      => try self.airIsNonErr(inst),
            .is_non_err_ptr  => @panic("TODO try self.airIsNonErrPtr(inst)"),
            .is_err          => try self.airIsErr(inst),
            .is_err_ptr      => @panic("TODO try self.airIsErrPtr(inst)"),
            .load            => try self.airLoad(inst),
            .loop            => try self.airLoop(inst),
            .not             => @panic("TODO try self.airNot(inst)"),
            .ptrtoint        => @panic("TODO try self.airPtrToInt(inst)"),
            .ret             => try self.airRet(inst),
            .ret_load        => try self.airRetLoad(inst),
            .store           => try self.airStore(inst),
            .struct_field_ptr=> @panic("TODO try self.airStructFieldPtr(inst)"),
            .struct_field_val=> @panic("TODO try self.airStructFieldVal(inst)"),
            .array_to_slice  => @panic("TODO try self.airArrayToSlice(inst)"),
            .int_to_float    => @panic("TODO try self.airIntToFloat(inst)"),
            .float_to_int    => @panic("TODO try self.airFloatToInt(inst)"),
            .cmpxchg_strong  => @panic("TODO try self.airCmpxchg(inst)"),
            .cmpxchg_weak    => @panic("TODO try self.airCmpxchg(inst)"),
            .atomic_rmw      => @panic("TODO try self.airAtomicRmw(inst)"),
            .atomic_load     => @panic("TODO try self.airAtomicLoad(inst)"),
            .memcpy          => @panic("TODO try self.airMemcpy(inst)"),
            .memset          => @panic("TODO try self.airMemset(inst)"),
            .set_union_tag   => @panic("TODO try self.airSetUnionTag(inst)"),
            .get_union_tag   => @panic("TODO try self.airGetUnionTag(inst)"),
            .clz             => @panic("TODO try self.airClz(inst)"),
            .ctz             => @panic("TODO try self.airCtz(inst)"),
            .popcount        => @panic("TODO try self.airPopcount(inst)"),
            .byte_swap       => @panic("TODO try self.airByteSwap(inst)"),
            .bit_reverse     => @panic("TODO try self.airBitReverse(inst)"),
            .tag_name        => @panic("TODO try self.airTagName(inst)"),
            .error_name      => @panic("TODO try self.airErrorName(inst)"),
            .splat           => @panic("TODO try self.airSplat(inst)"),
            .select          => @panic("TODO try self.airSelect(inst)"),
            .shuffle         => @panic("TODO try self.airShuffle(inst)"),
            .reduce          => @panic("TODO try self.airReduce(inst)"),
            .aggregate_init  => @panic("TODO try self.airAggregateInit(inst)"),
            .union_init      => @panic("TODO try self.airUnionInit(inst)"),
            .prefetch        => @panic("TODO try self.airPrefetch(inst)"),
            .mul_add         => @panic("TODO try self.airMulAdd(inst)"),

            .dbg_var_ptr,
            .dbg_var_val,
            => try self.airDbgVar(inst),

            .dbg_inline_begin,
            .dbg_inline_end,
            => try self.airDbgInline(inst),

            .dbg_block_begin,
            .dbg_block_end,
            => try self.airDbgBlock(inst),

            .call              => try self.airCall(inst, .auto),
            .call_always_tail  => try self.airCall(inst, .always_tail),
            .call_never_tail   => try self.airCall(inst, .never_tail),
            .call_never_inline => try self.airCall(inst, .never_inline),

            .atomic_store_unordered => @panic("TODO try self.airAtomicStore(inst, .Unordered)"),
            .atomic_store_monotonic => @panic("TODO try self.airAtomicStore(inst, .Monotonic)"),
            .atomic_store_release   => @panic("TODO try self.airAtomicStore(inst, .Release)"),
            .atomic_store_seq_cst   => @panic("TODO try self.airAtomicStore(inst, .SeqCst)"),

            .struct_field_ptr_index_0 => try self.airStructFieldPtrIndex(inst, 0),
            .struct_field_ptr_index_1 => try self.airStructFieldPtrIndex(inst, 1),
            .struct_field_ptr_index_2 => try self.airStructFieldPtrIndex(inst, 2),
            .struct_field_ptr_index_3 => try self.airStructFieldPtrIndex(inst, 3),

            .field_parent_ptr => @panic("TODO try self.airFieldParentPtr(inst)"),

            .switch_br       => try self.airSwitch(inst),
            .slice_ptr       => @panic("TODO try self.airSlicePtr(inst)"),
            .slice_len       => try self.airSliceLen(inst),

            .ptr_slice_len_ptr => @panic("TODO try self.airPtrSliceLenPtr(inst)"),
            .ptr_slice_ptr_ptr => @panic("TODO try self.airPtrSlicePtrPtr(inst)"),

            .array_elem_val      => @panic("TODO try self.airArrayElemVal(inst)"),
            .slice_elem_val      => try self.airSliceElemVal(inst),
            .slice_elem_ptr      => @panic("TODO try self.airSliceElemPtr(inst)"),
            .ptr_elem_val        => @panic("TODO try self.airPtrElemVal(inst)"),
            .ptr_elem_ptr        => @panic("TODO try self.airPtrElemPtr(inst)"),

            .constant => unreachable, // excluded from function bodies
            .const_ty => unreachable, // excluded from function bodies
            .unreach  => self.finishAirBookkeeping(),

            .optional_payload           => @panic("TODO try self.airOptionalPayload(inst)"),
            .optional_payload_ptr       => @panic("TODO try self.airOptionalPayloadPtr(inst)"),
            .optional_payload_ptr_set   => @panic("TODO try self.airOptionalPayloadPtrSet(inst)"),
            .unwrap_errunion_err        => try self.airUnwrapErrErr(inst),
            .unwrap_errunion_payload    => try self.airUnwrapErrPayload(inst),
            .unwrap_errunion_err_ptr    => @panic("TODO try self.airUnwrapErrErrPtr(inst)"),
            .unwrap_errunion_payload_ptr=> @panic("TODO try self.airUnwrapErrPayloadPtr(inst)"),
            .errunion_payload_ptr_set   => @panic("TODO try self.airErrUnionPayloadPtrSet(inst)"),
            .err_return_trace           => @panic("TODO try self.airErrReturnTrace(inst)"),
            .set_err_return_trace       => @panic("TODO try self.airSetErrReturnTrace(inst)"),

            .wrap_optional         => @panic("TODO try self.airWrapOptional(inst)"),
            .wrap_errunion_payload => @panic("TODO try self.airWrapErrUnionPayload(inst)"),
            .wrap_errunion_err     => @panic("TODO try self.airWrapErrUnionErr(inst)"),

            .wasm_memory_size => unreachable,
            .wasm_memory_grow => unreachable,
            // zig fmt: on
        }

        if (std.debug.runtime_safety) {
            if (self.air_bookkeeping < old_air_bookkeeping + 1) {
                std.debug.panic("in codegen.zig, handling of AIR instruction %{d} ('{}') did not do proper bookkeeping. Look for a missing call to finishAir.", .{ inst, air_tags[inst] });
            }
        }
    }
}

fn airAlloc(self: *Self, inst: Air.Inst.Index) !void {
    const stack_offset = try self.allocMemPtr(inst);
    return self.finishAir(inst, .{ .ptr_stack_offset = stack_offset }, .{ .none, .none, .none });
}

fn airAsm(self: *Self, inst: Air.Inst.Index) !void {
    const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
    const extra = self.air.extraData(Air.Asm, ty_pl.payload);
    const is_volatile = (extra.data.flags & 0x80000000) != 0;
    const clobbers_len = @truncate(u31, extra.data.flags);
    var extra_i: usize = extra.end;
    const outputs = @ptrCast([]const Air.Inst.Ref, self.air.extra[extra_i .. extra_i + extra.data.outputs_len]);
    extra_i += outputs.len;
    const inputs = @ptrCast([]const Air.Inst.Ref, self.air.extra[extra_i .. extra_i + extra.data.inputs_len]);
    extra_i += inputs.len;

    const dead = !is_volatile and self.liveness.isUnused(inst);
    const result: MCValue = if (dead) .dead else result: {
        if (outputs.len > 1) {
            return self.fail("TODO implement codegen for asm with more than 1 output", .{});
        }

        const output_constraint: ?[]const u8 = for (outputs) |output| {
            if (output != .none) {
                return self.fail("TODO implement codegen for non-expr asm", .{});
            }
            const extra_bytes = std.mem.sliceAsBytes(self.air.extra[extra_i..]);
            const constraint = std.mem.sliceTo(std.mem.sliceAsBytes(self.air.extra[extra_i..]), 0);
            const name = std.mem.sliceTo(extra_bytes[constraint.len + 1 ..], 0);
            // This equation accounts for the fact that even if we have exactly 4 bytes
            // for the string, we still use the next u32 for the null terminator.
            extra_i += (constraint.len + name.len + (2 + 3)) / 4;

            break constraint;
        } else null;

        for (inputs) |input| {
            const input_bytes = std.mem.sliceAsBytes(self.air.extra[extra_i..]);
            const constraint = std.mem.sliceTo(input_bytes, 0);
            const name = std.mem.sliceTo(input_bytes[constraint.len + 1 ..], 0);
            // This equation accounts for the fact that even if we have exactly 4 bytes
            // for the string, we still use the next u32 for the null terminator.
            extra_i += (constraint.len + name.len + (2 + 3)) / 4;

            if (constraint.len < 3 or constraint[0] != '{' or constraint[constraint.len - 1] != '}') {
                return self.fail("unrecognized asm input constraint: '{s}'", .{constraint});
            }
            const reg_name = constraint[1 .. constraint.len - 1];
            const reg = parseRegName(reg_name) orelse
                return self.fail("unrecognized register: '{s}'", .{reg_name});

            const arg_mcv = try self.resolveInst(input);
            try self.register_manager.getReg(reg, null);
            try self.genSetReg(self.air.typeOf(input), reg, arg_mcv);
        }

        {
            var clobber_i: u32 = 0;
            while (clobber_i < clobbers_len) : (clobber_i += 1) {
                const clobber = std.mem.sliceTo(std.mem.sliceAsBytes(self.air.extra[extra_i..]), 0);
                // This equation accounts for the fact that even if we have exactly 4 bytes
                // for the string, we still use the next u32 for the null terminator.
                extra_i += clobber.len / 4 + 1;

                // TODO honor these
            }
        }

        const asm_source = std.mem.sliceAsBytes(self.air.extra[extra_i..])[0..extra.data.source_len];

        if (mem.eql(u8, asm_source, "ta 0x6d")) {
            _ = try self.addInst(.{
                .tag = .tcc,
                .data = .{
                    .trap = .{
                        .is_imm = true,
                        .cond = .al,
                        .rs2_or_imm = .{ .imm = 0x6d },
                    },
                },
            });
        } else {
            return self.fail("TODO implement a full SPARCv9 assembly parsing", .{});
        }

        if (output_constraint) |output| {
            if (output.len < 4 or output[0] != '=' or output[1] != '{' or output[output.len - 1] != '}') {
                return self.fail("unrecognized asm output constraint: '{s}'", .{output});
            }
            const reg_name = output[2 .. output.len - 1];
            const reg = parseRegName(reg_name) orelse
                return self.fail("unrecognized register: '{s}'", .{reg_name});
            break :result MCValue{ .register = reg };
        } else {
            break :result MCValue{ .none = {} };
        }
    };

    simple: {
        var buf = [1]Air.Inst.Ref{.none} ** (Liveness.bpi - 1);
        var buf_index: usize = 0;
        for (outputs) |output| {
            if (output == .none) continue;

            if (buf_index >= buf.len) break :simple;
            buf[buf_index] = output;
            buf_index += 1;
        }
        if (buf_index + inputs.len > buf.len) break :simple;
        std.mem.copy(Air.Inst.Ref, buf[buf_index..], inputs);
        return self.finishAir(inst, result, buf);
    }

    var bt = try self.iterateBigTomb(inst, outputs.len + inputs.len);
    for (outputs) |output| {
        if (output == .none) continue;

        bt.feed(output);
    }
    for (inputs) |input| {
        bt.feed(input);
    }
    return bt.finishAir(result);
}

fn airArg(self: *Self, inst: Air.Inst.Index) !void {
    const arg_index = self.arg_index;
    self.arg_index += 1;

    const ty = self.air.typeOfIndex(inst);
    _ = ty;

    const result = self.args[arg_index];
    // TODO support stack-only arguments
    // TODO Copy registers to the stack
    const mcv = result;

    try self.genArgDbgInfo(inst, mcv, @intCast(u32, arg_index));

    if (self.liveness.isUnused(inst))
        return self.finishAirBookkeeping();

    switch (mcv) {
        .register => |reg| {
            self.register_manager.getRegAssumeFree(reg, inst);
        },
        else => {},
    }

    return self.finishAir(inst, mcv, .{ .none, .none, .none });
}

fn airBinOp(self: *Self, inst: Air.Inst.Index, tag: Air.Inst.Tag) !void {
    const bin_op = self.air.instructions.items(.data)[inst].bin_op;
    const lhs = try self.resolveInst(bin_op.lhs);
    const rhs = try self.resolveInst(bin_op.rhs);
    const lhs_ty = self.air.typeOf(bin_op.lhs);
    const rhs_ty = self.air.typeOf(bin_op.rhs);
    const result: MCValue = if (self.liveness.isUnused(inst))
        .dead
    else
        try self.binOp(tag, lhs, rhs, lhs_ty, rhs_ty, BinOpMetadata{
            .lhs = bin_op.lhs,
            .rhs = bin_op.rhs,
            .inst = inst,
        });
    return self.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airPtrArithmetic(self: *Self, inst: Air.Inst.Index, tag: Air.Inst.Tag) !void {
    const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
    const bin_op = self.air.extraData(Air.Bin, ty_pl.payload).data;
    const lhs = try self.resolveInst(bin_op.lhs);
    const rhs = try self.resolveInst(bin_op.rhs);
    const lhs_ty = self.air.typeOf(bin_op.lhs);
    const rhs_ty = self.air.typeOf(bin_op.rhs);
    const result: MCValue = if (self.liveness.isUnused(inst))
        .dead
    else
        try self.binOp(tag, lhs, rhs, lhs_ty, rhs_ty, BinOpMetadata{
            .lhs = bin_op.lhs,
            .rhs = bin_op.rhs,
            .inst = inst,
        });
    return self.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airBitCast(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    const result = try self.resolveInst(ty_op.operand);
    return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airBlock(self: *Self, inst: Air.Inst.Index) !void {
    try self.blocks.putNoClobber(self.gpa, inst, .{
        // A block is a setup to be able to jump to the end.
        .relocs = .{},
        // It also acts as a receptacle for break operands.
        // Here we use `MCValue.none` to represent a null value so that the first
        // break instruction will choose a MCValue for the block result and overwrite
        // this field. Following break instructions will use that MCValue to put their
        // block results.
        .mcv = MCValue{ .none = {} },
    });
    defer self.blocks.getPtr(inst).?.relocs.deinit(self.gpa);

    const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
    const extra = self.air.extraData(Air.Block, ty_pl.payload);
    const body = self.air.extra[extra.end..][0..extra.data.body_len];
    try self.genBody(body);

    // relocations for `bpcc` instructions
    const relocs = &self.blocks.getPtr(inst).?.relocs;
    if (relocs.items.len > 0 and relocs.items[relocs.items.len - 1] == self.mir_instructions.len - 1) {
        // If the last Mir instruction is the last relocation (which
        // would just jump one instruction further), it can be safely
        // removed
        self.mir_instructions.orderedRemove(relocs.pop());
    }
    for (relocs.items) |reloc| {
        try self.performReloc(reloc);
    }

    const result = self.blocks.getPtr(inst).?.mcv;
    return self.finishAir(inst, result, .{ .none, .none, .none });
}

fn airBr(self: *Self, inst: Air.Inst.Index) !void {
    const branch = self.air.instructions.items(.data)[inst].br;
    try self.br(branch.block_inst, branch.operand);
    return self.finishAir(inst, .dead, .{ branch.operand, .none, .none });
}

fn airBreakpoint(self: *Self) !void {
    // ta 0x01
    _ = try self.addInst(.{
        .tag = .tcc,
        .data = .{
            .trap = .{
                .is_imm = true,
                .cond = .al,
                .rs2_or_imm = .{ .imm = 0x01 },
            },
        },
    });
    return self.finishAirBookkeeping();
}

fn airCall(self: *Self, inst: Air.Inst.Index, modifier: std.builtin.CallOptions.Modifier) !void {
    if (modifier == .always_tail) return self.fail("TODO implement tail calls for {}", .{self.target.cpu.arch});

    const pl_op = self.air.instructions.items(.data)[inst].pl_op;
    const callee = pl_op.operand;
    const extra = self.air.extraData(Air.Call, pl_op.payload);
    const args = @ptrCast([]const Air.Inst.Ref, self.air.extra[extra.end .. extra.end + extra.data.args_len]);
    const ty = self.air.typeOf(callee);
    const fn_ty = switch (ty.zigTypeTag()) {
        .Fn => ty,
        .Pointer => ty.childType(),
        else => unreachable,
    };

    var info = try self.resolveCallingConventionValues(fn_ty, .caller);
    defer info.deinit(self);
    for (info.args) |mc_arg, arg_i| {
        const arg = args[arg_i];
        const arg_ty = self.air.typeOf(arg);
        const arg_mcv = try self.resolveInst(arg);

        switch (mc_arg) {
            .none => continue,
            .undef => unreachable,
            .immediate => unreachable,
            .unreach => unreachable,
            .dead => unreachable,
            .memory => unreachable,
            .compare_flags_signed => unreachable,
            .compare_flags_unsigned => unreachable,
            .register => |reg| {
                try self.register_manager.getReg(reg, null);
                try self.genSetReg(arg_ty, reg, arg_mcv);
            },
            .stack_offset => {
                return self.fail("TODO implement calling with parameters in memory", .{});
            },
            .ptr_stack_offset => {
                return self.fail("TODO implement calling with MCValue.ptr_stack_offset arg", .{});
            },
        }
    }

    // Due to incremental compilation, how function calls are generated depends
    // on linking.
    if (self.air.value(callee)) |func_value| {
        if (self.bin_file.tag == link.File.Elf.base_tag) {
            if (func_value.castTag(.function)) |func_payload| {
                const func = func_payload.data;
                const ptr_bits = self.target.cpu.arch.ptrBitWidth();
                const ptr_bytes: u64 = @divExact(ptr_bits, 8);
                const got_addr = if (self.bin_file.cast(link.File.Elf)) |elf_file| blk: {
                    const got = &elf_file.program_headers.items[elf_file.phdr_got_index.?];
                    const mod = self.bin_file.options.module.?;
                    break :blk @intCast(u32, got.p_vaddr + mod.declPtr(func.owner_decl).link.elf.offset_table_index * ptr_bytes);
                } else unreachable;

                try self.genSetReg(Type.initTag(.usize), .o7, .{ .memory = got_addr });

                _ = try self.addInst(.{
                    .tag = .jmpl,
                    .data = .{
                        .arithmetic_3op = .{
                            .is_imm = false,
                            .rd = .o7,
                            .rs1 = .o7,
                            .rs2_or_imm = .{ .rs2 = .g0 },
                        },
                    },
                });

                // TODO Find a way to fill this delay slot
                _ = try self.addInst(.{
                    .tag = .nop,
                    .data = .{ .nop = {} },
                });
            } else if (func_value.castTag(.extern_fn)) |_| {
                return self.fail("TODO implement calling extern functions", .{});
            } else {
                return self.fail("TODO implement calling bitcasted functions", .{});
            }
        } else @panic("TODO SPARCv9 currently does not support non-ELF binaries");
    } else {
        assert(ty.zigTypeTag() == .Pointer);
        const mcv = try self.resolveInst(callee);
        try self.genSetReg(ty, .o7, mcv);

        _ = try self.addInst(.{
            .tag = .jmpl,
            .data = .{
                .arithmetic_3op = .{
                    .is_imm = false,
                    .rd = .o7,
                    .rs1 = .o7,
                    .rs2_or_imm = .{ .rs2 = .g0 },
                },
            },
        });

        // TODO Find a way to fill this delay slot
        _ = try self.addInst(.{
            .tag = .nop,
            .data = .{ .nop = {} },
        });
    }

    const result = info.return_value;

    if (args.len + 1 <= Liveness.bpi - 1) {
        var buf = [1]Air.Inst.Ref{.none} ** (Liveness.bpi - 1);
        buf[0] = callee;
        std.mem.copy(Air.Inst.Ref, buf[1..], args);
        return self.finishAir(inst, result, buf);
    }

    @panic("TODO handle return value with BigTomb");
}

fn airCmp(self: *Self, inst: Air.Inst.Index, op: math.CompareOperator) !void {
    const bin_op = self.air.instructions.items(.data)[inst].bin_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else result: {
        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);
        const lhs_ty = self.air.typeOf(bin_op.lhs);

        var int_buffer: Type.Payload.Bits = undefined;
        const int_ty = switch (lhs_ty.zigTypeTag()) {
            .Vector => unreachable, // Handled by cmp_vector.
            .Enum => lhs_ty.intTagType(&int_buffer),
            .Int => lhs_ty,
            .Bool => Type.initTag(.u1),
            .Pointer => Type.usize,
            .ErrorSet => Type.initTag(.u16),
            .Optional => blk: {
                var opt_buffer: Type.Payload.ElemType = undefined;
                const payload_ty = lhs_ty.optionalChild(&opt_buffer);
                if (!payload_ty.hasRuntimeBitsIgnoreComptime()) {
                    break :blk Type.initTag(.u1);
                } else if (lhs_ty.isPtrLikeOptional()) {
                    break :blk Type.usize;
                } else {
                    return self.fail("TODO SPARCv9 cmp non-pointer optionals", .{});
                }
            },
            .Float => return self.fail("TODO SPARCv9 cmp floats", .{}),
            else => unreachable,
        };

        const int_info = int_ty.intInfo(self.target.*);
        if (int_info.bits <= 64) {
            _ = try self.binOp(.cmp_eq, lhs, rhs, int_ty, int_ty, BinOpMetadata{
                .lhs = bin_op.lhs,
                .rhs = bin_op.rhs,
                .inst = inst,
            });

            try self.spillCompareFlagsIfOccupied();
            self.compare_flags_inst = inst;

            break :result switch (int_info.signedness) {
                .signed => MCValue{ .compare_flags_signed = .{ .cmp = op, .ccr = .xcc } },
                .unsigned => MCValue{ .compare_flags_unsigned = .{ .cmp = op, .ccr = .xcc } },
            };
        } else {
            return self.fail("TODO SPARCv9 cmp for ints > 64 bits", .{});
        }
    };
    return self.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airCondBr(self: *Self, inst: Air.Inst.Index) !void {
    const pl_op = self.air.instructions.items(.data)[inst].pl_op;
    const cond = try self.resolveInst(pl_op.operand);
    const extra = self.air.extraData(Air.CondBr, pl_op.payload);
    const then_body = self.air.extra[extra.end..][0..extra.data.then_body_len];
    const else_body = self.air.extra[extra.end + then_body.len ..][0..extra.data.else_body_len];
    const liveness_condbr = self.liveness.getCondBr(inst);

    // Here we either emit a BPcc for branching on CCR content,
    // or emit a BPr to branch on register content.
    const reloc: Mir.Inst.Index = switch (cond) {
        .compare_flags_signed,
        .compare_flags_unsigned,
        => try self.addInst(.{
            .tag = .bpcc,
            .data = .{
                .branch_predict_int = .{
                    .ccr = switch (cond) {
                        .compare_flags_signed => |cmp_op| cmp_op.ccr,
                        .compare_flags_unsigned => |cmp_op| cmp_op.ccr,
                        else => unreachable,
                    },
                    .cond = switch (cond) {
                        .compare_flags_signed => |cmp_op| blk: {
                            // Here we map to the opposite condition because the jump is to the false branch.
                            const condition = Instruction.ICondition.fromCompareOperatorSigned(cmp_op.cmp);
                            break :blk condition.negate();
                        },
                        .compare_flags_unsigned => |cmp_op| blk: {
                            // Here we map to the opposite condition because the jump is to the false branch.
                            const condition = Instruction.ICondition.fromCompareOperatorUnsigned(cmp_op.cmp);
                            break :blk condition.negate();
                        },
                        else => unreachable,
                    },
                    .inst = undefined, // Will be filled by performReloc
                },
            },
        }),
        else => blk: {
            const reg = switch (cond) {
                .register => |r| r,
                else => try self.copyToTmpRegister(Type.bool, cond),
            };

            break :blk try self.addInst(.{
                .tag = .bpr,
                .data = .{
                    .branch_predict_reg = .{
                        .cond = .eq_zero,
                        .rs1 = reg,
                        .inst = undefined, // populated later through performReloc
                    },
                },
            });
        },
    };

    // Regardless of the branch type that's emitted, we need to reserve
    // a space for the delay slot.
    // TODO Find a way to fill this delay slot
    _ = try self.addInst(.{
        .tag = .nop,
        .data = .{ .nop = {} },
    });

    // If the condition dies here in this condbr instruction, process
    // that death now instead of later as this has an effect on
    // whether it needs to be spilled in the branches
    if (self.liveness.operandDies(inst, 0)) {
        const op_int = @enumToInt(pl_op.operand);
        if (op_int >= Air.Inst.Ref.typed_value_map.len) {
            const op_index = @intCast(Air.Inst.Index, op_int - Air.Inst.Ref.typed_value_map.len);
            self.processDeath(op_index);
        }
    }

    // Capture the state of register and stack allocation state so that we can revert to it.
    const parent_next_stack_offset = self.next_stack_offset;
    const parent_free_registers = self.register_manager.free_registers;
    var parent_stack = try self.stack.clone(self.gpa);
    defer parent_stack.deinit(self.gpa);
    const parent_registers = self.register_manager.registers;
    const parent_compare_flags_inst = self.compare_flags_inst;

    try self.branch_stack.append(.{});
    errdefer {
        _ = self.branch_stack.pop();
    }

    try self.ensureProcessDeathCapacity(liveness_condbr.then_deaths.len);
    for (liveness_condbr.then_deaths) |operand| {
        self.processDeath(operand);
    }
    try self.genBody(then_body);

    // Revert to the previous register and stack allocation state.

    var saved_then_branch = self.branch_stack.pop();
    defer saved_then_branch.deinit(self.gpa);

    self.register_manager.registers = parent_registers;
    self.compare_flags_inst = parent_compare_flags_inst;

    self.stack.deinit(self.gpa);
    self.stack = parent_stack;
    parent_stack = .{};

    self.next_stack_offset = parent_next_stack_offset;
    self.register_manager.free_registers = parent_free_registers;

    try self.performReloc(reloc);
    const else_branch = self.branch_stack.addOneAssumeCapacity();
    else_branch.* = .{};

    try self.ensureProcessDeathCapacity(liveness_condbr.else_deaths.len);
    for (liveness_condbr.else_deaths) |operand| {
        self.processDeath(operand);
    }
    try self.genBody(else_body);

    // At this point, each branch will possibly have conflicting values for where
    // each instruction is stored. They agree, however, on which instructions are alive/dead.
    // We use the first ("then") branch as canonical, and here emit
    // instructions into the second ("else") branch to make it conform.
    // We continue respect the data structure semantic guarantees of the else_branch so
    // that we can use all the code emitting abstractions. This is why at the bottom we
    // assert that parent_branch.free_registers equals the saved_then_branch.free_registers
    // rather than assigning it.
    const parent_branch = &self.branch_stack.items[self.branch_stack.items.len - 2];
    try parent_branch.inst_table.ensureUnusedCapacity(self.gpa, else_branch.inst_table.count());

    const else_slice = else_branch.inst_table.entries.slice();
    const else_keys = else_slice.items(.key);
    const else_values = else_slice.items(.value);
    for (else_keys) |else_key, else_idx| {
        const else_value = else_values[else_idx];
        const canon_mcv = if (saved_then_branch.inst_table.fetchSwapRemove(else_key)) |then_entry| blk: {
            // The instruction's MCValue is overridden in both branches.
            parent_branch.inst_table.putAssumeCapacity(else_key, then_entry.value);
            if (else_value == .dead) {
                assert(then_entry.value == .dead);
                continue;
            }
            break :blk then_entry.value;
        } else blk: {
            if (else_value == .dead)
                continue;
            // The instruction is only overridden in the else branch.
            var i: usize = self.branch_stack.items.len - 2;
            while (true) {
                i -= 1; // If this overflows, the question is: why wasn't the instruction marked dead?
                if (self.branch_stack.items[i].inst_table.get(else_key)) |mcv| {
                    assert(mcv != .dead);
                    break :blk mcv;
                }
            }
        };
        log.debug("consolidating else_entry {d} {}=>{}", .{ else_key, else_value, canon_mcv });
        // TODO make sure the destination stack offset / register does not already have something
        // going on there.
        try self.setRegOrMem(self.air.typeOfIndex(else_key), canon_mcv, else_value);
        // TODO track the new register / stack allocation
    }
    try parent_branch.inst_table.ensureUnusedCapacity(self.gpa, saved_then_branch.inst_table.count());
    const then_slice = saved_then_branch.inst_table.entries.slice();
    const then_keys = then_slice.items(.key);
    const then_values = then_slice.items(.value);
    for (then_keys) |then_key, then_idx| {
        const then_value = then_values[then_idx];
        // We already deleted the items from this table that matched the else_branch.
        // So these are all instructions that are only overridden in the then branch.
        parent_branch.inst_table.putAssumeCapacity(then_key, then_value);
        if (then_value == .dead)
            continue;
        const parent_mcv = blk: {
            var i: usize = self.branch_stack.items.len - 2;
            while (true) {
                i -= 1;
                if (self.branch_stack.items[i].inst_table.get(then_key)) |mcv| {
                    assert(mcv != .dead);
                    break :blk mcv;
                }
            }
        };
        log.debug("consolidating then_entry {d} {}=>{}", .{ then_key, parent_mcv, then_value });
        // TODO make sure the destination stack offset / register does not already have something
        // going on there.
        try self.setRegOrMem(self.air.typeOfIndex(then_key), parent_mcv, then_value);
        // TODO track the new register / stack allocation
    }

    {
        var item = self.branch_stack.pop();
        item.deinit(self.gpa);
    }

    // We already took care of pl_op.operand earlier, so we're going
    // to pass .none here
    return self.finishAir(inst, .unreach, .{ .none, .none, .none });
}

fn airDbgBlock(self: *Self, inst: Air.Inst.Index) !void {
    // TODO emit debug info lexical block
    return self.finishAir(inst, .dead, .{ .none, .none, .none });
}

fn airDbgInline(self: *Self, inst: Air.Inst.Index) !void {
    const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
    const function = self.air.values[ty_pl.payload].castTag(.function).?.data;
    // TODO emit debug info for function change
    _ = function;
    return self.finishAir(inst, .dead, .{ .none, .none, .none });
}

fn airDbgStmt(self: *Self, inst: Air.Inst.Index) !void {
    const dbg_stmt = self.air.instructions.items(.data)[inst].dbg_stmt;

    _ = try self.addInst(.{
        .tag = .dbg_line,
        .data = .{
            .dbg_line_column = .{
                .line = dbg_stmt.line,
                .column = dbg_stmt.column,
            },
        },
    });

    return self.finishAirBookkeeping();
}

fn airDbgVar(self: *Self, inst: Air.Inst.Index) !void {
    const pl_op = self.air.instructions.items(.data)[inst].pl_op;
    const name = self.air.nullTerminatedString(pl_op.payload);
    const operand = pl_op.operand;
    // TODO emit debug info for this variable
    _ = name;
    return self.finishAir(inst, .dead, .{ operand, .none, .none });
}

fn airDiv(self: *Self, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[inst].bin_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else return self.fail("TODO implement div for {}", .{self.target.cpu.arch});
    return self.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airIsErr(self: *Self, inst: Air.Inst.Index) !void {
    const un_op = self.air.instructions.items(.data)[inst].un_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else result: {
        const operand = try self.resolveInst(un_op);
        const ty = self.air.typeOf(un_op);
        break :result try self.isErr(ty, operand);
    };
    return self.finishAir(inst, result, .{ un_op, .none, .none });
}

fn airIsNonErr(self: *Self, inst: Air.Inst.Index) !void {
    const un_op = self.air.instructions.items(.data)[inst].un_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else result: {
        const operand = try self.resolveInst(un_op);
        const ty = self.air.typeOf(un_op);
        break :result try self.isNonErr(ty, operand);
    };
    return self.finishAir(inst, result, .{ un_op, .none, .none });
}

fn airLoad(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    const elem_ty = self.air.typeOfIndex(inst);
    const elem_size = elem_ty.abiSize(self.target.*);
    const result: MCValue = result: {
        if (!elem_ty.hasRuntimeBits())
            break :result MCValue.none;

        const ptr = try self.resolveInst(ty_op.operand);
        const is_volatile = self.air.typeOf(ty_op.operand).isVolatilePtr();
        if (self.liveness.isUnused(inst) and !is_volatile)
            break :result MCValue.dead;

        const dst_mcv: MCValue = blk: {
            if (elem_size <= 8 and self.reuseOperand(inst, ty_op.operand, 0, ptr)) {
                // The MCValue that holds the pointer can be re-used as the value.
                break :blk switch (ptr) {
                    .register => |r| MCValue{ .register = r },
                    else => ptr,
                };
            } else {
                break :blk try self.allocRegOrMem(inst, true);
            }
        };
        try self.load(dst_mcv, ptr, self.air.typeOf(ty_op.operand));
        break :result dst_mcv;
    };
    return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airLoop(self: *Self, inst: Air.Inst.Index) !void {
    // A loop is a setup to be able to jump back to the beginning.
    const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
    const loop = self.air.extraData(Air.Block, ty_pl.payload);
    const body = self.air.extra[loop.end .. loop.end + loop.data.body_len];
    const start = @intCast(u32, self.mir_instructions.len);
    try self.genBody(body);
    try self.jump(start);
    return self.finishAirBookkeeping();
}

fn airRet(self: *Self, inst: Air.Inst.Index) !void {
    const un_op = self.air.instructions.items(.data)[inst].un_op;
    const operand = try self.resolveInst(un_op);
    try self.ret(operand);
    return self.finishAir(inst, .dead, .{ un_op, .none, .none });
}

fn airRetLoad(self: *Self, inst: Air.Inst.Index) !void {
    const un_op = self.air.instructions.items(.data)[inst].un_op;
    const ptr = try self.resolveInst(un_op);
    _ = ptr;
    return self.fail("TODO implement airRetLoad for {}", .{self.target.cpu.arch});
    //return self.finishAir(inst, .dead, .{ un_op, .none, .none });
}

fn airRetPtr(self: *Self, inst: Air.Inst.Index) !void {
    const stack_offset = try self.allocMemPtr(inst);
    return self.finishAir(inst, .{ .ptr_stack_offset = stack_offset }, .{ .none, .none, .none });
}

fn airSliceElemVal(self: *Self, inst: Air.Inst.Index) !void {
    const is_volatile = false; // TODO
    const bin_op = self.air.instructions.items(.data)[inst].bin_op;

    if (!is_volatile and self.liveness.isUnused(inst)) return self.finishAir(inst, .dead, .{ bin_op.lhs, bin_op.rhs, .none });
    const result: MCValue = result: {
        const slice_mcv = try self.resolveInst(bin_op.lhs);
        const index_mcv = try self.resolveInst(bin_op.rhs);

        const slice_ty = self.air.typeOf(bin_op.lhs);
        const elem_ty = slice_ty.childType();
        const elem_size = elem_ty.abiSize(self.target.*);

        var buf: Type.SlicePtrFieldTypeBuffer = undefined;
        const slice_ptr_field_type = slice_ty.slicePtrFieldType(&buf);

        const index_lock: ?RegisterLock = if (index_mcv == .register)
            self.register_manager.lockRegAssumeUnused(index_mcv.register)
        else
            null;
        defer if (index_lock) |reg| self.register_manager.unlockReg(reg);

        const base_mcv: MCValue = switch (slice_mcv) {
            .stack_offset => |off| .{ .register = try self.copyToTmpRegister(slice_ptr_field_type, .{ .stack_offset = off }) },
            else => return self.fail("TODO slice_elem_val when slice is {}", .{slice_mcv}),
        };
        const base_lock = self.register_manager.lockRegAssumeUnused(base_mcv.register);
        defer self.register_manager.unlockReg(base_lock);

        switch (elem_size) {
            else => {
                // TODO skip the ptr_add emission entirely and use native addressing modes
                // i.e sllx/mulx then R+R or scale immediate then R+I
                const dest = try self.allocRegOrMem(inst, true);
                const addr = try self.binOp(.ptr_add, base_mcv, index_mcv, slice_ptr_field_type, Type.usize, null);
                try self.load(dest, addr, slice_ptr_field_type);

                break :result dest;
            },
        }
    };
    return self.finishAir(inst, result, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airSliceLen(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else result: {
        const ptr_bits = self.target.cpu.arch.ptrBitWidth();
        const ptr_bytes = @divExact(ptr_bits, 8);
        const mcv = try self.resolveInst(ty_op.operand);
        switch (mcv) {
            .dead, .unreach, .none => unreachable,
            .register => unreachable, // a slice doesn't fit in one register
            .stack_offset => |off| {
                break :result MCValue{ .stack_offset = off - ptr_bytes };
            },
            .memory => |addr| {
                break :result MCValue{ .memory = addr + ptr_bytes };
            },
            else => return self.fail("TODO implement slice_len for {}", .{mcv}),
        }
    };
    return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airStore(self: *Self, inst: Air.Inst.Index) !void {
    const bin_op = self.air.instructions.items(.data)[inst].bin_op;
    const ptr = try self.resolveInst(bin_op.lhs);
    const value = try self.resolveInst(bin_op.rhs);
    const ptr_ty = self.air.typeOf(bin_op.lhs);
    const value_ty = self.air.typeOf(bin_op.rhs);

    try self.store(ptr, value, ptr_ty, value_ty);

    return self.finishAir(inst, .dead, .{ bin_op.lhs, bin_op.rhs, .none });
}

fn airStructFieldPtrIndex(self: *Self, inst: Air.Inst.Index, index: u8) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    const result = try self.structFieldPtr(inst, ty_op.operand, index);
    return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airSwitch(self: *Self, inst: Air.Inst.Index) !void {
    _ = self;
    _ = inst;

    return self.fail("TODO implement switch for {}", .{self.target.cpu.arch});
}

fn airUnwrapErrErr(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else result: {
        const error_union_ty = self.air.typeOf(ty_op.operand);
        const payload_ty = error_union_ty.errorUnionPayload();
        const mcv = try self.resolveInst(ty_op.operand);
        if (!payload_ty.hasRuntimeBits()) break :result mcv;

        return self.fail("TODO implement unwrap error union error for non-empty payloads", .{});
    };
    return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

fn airUnwrapErrPayload(self: *Self, inst: Air.Inst.Index) !void {
    const ty_op = self.air.instructions.items(.data)[inst].ty_op;
    const result: MCValue = if (self.liveness.isUnused(inst)) .dead else result: {
        const error_union_ty = self.air.typeOf(ty_op.operand);
        const payload_ty = error_union_ty.errorUnionPayload();
        if (!payload_ty.hasRuntimeBits()) break :result MCValue.none;

        return self.fail("TODO implement unwrap error union payload for non-empty payloads", .{});
    };
    return self.finishAir(inst, result, .{ ty_op.operand, .none, .none });
}

// Common helper functions

/// Adds a Type to the .debug_info at the current position. The bytes will be populated later,
/// after codegen for this symbol is done.
fn addDbgInfoTypeReloc(self: *Self, ty: Type) !void {
    switch (self.debug_output) {
        .dwarf => |dw| {
            assert(ty.hasRuntimeBits());
            const dbg_info = &dw.dbg_info;
            const index = dbg_info.items.len;
            try dbg_info.resize(index + 4); // DW.AT.type,  DW.FORM.ref4
            const mod = self.bin_file.options.module.?;
            const atom = switch (self.bin_file.tag) {
                .elf => &mod.declPtr(self.mod_fn.owner_decl).link.elf.dbg_info_atom,
                else => unreachable,
            };
            try dw.addTypeReloc(atom, ty, @intCast(u32, index), null);
        },
        else => {},
    }
}

fn addInst(self: *Self, inst: Mir.Inst) error{OutOfMemory}!Mir.Inst.Index {
    const gpa = self.gpa;
    try self.mir_instructions.ensureUnusedCapacity(gpa, 1);
    const result_index = @intCast(Air.Inst.Index, self.mir_instructions.len);
    self.mir_instructions.appendAssumeCapacity(inst);
    return result_index;
}

fn allocMem(self: *Self, inst: Air.Inst.Index, abi_size: u32, abi_align: u32) !u32 {
    if (abi_align > self.stack_align)
        self.stack_align = abi_align;
    // TODO find a free slot instead of always appending
    const offset = mem.alignForwardGeneric(u32, self.next_stack_offset, abi_align);
    self.next_stack_offset = offset + abi_size;
    if (self.next_stack_offset > self.max_end_stack)
        self.max_end_stack = self.next_stack_offset;
    try self.stack.putNoClobber(self.gpa, offset, .{
        .inst = inst,
        .size = abi_size,
    });
    return offset;
}

/// Use a pointer instruction as the basis for allocating stack memory.
fn allocMemPtr(self: *Self, inst: Air.Inst.Index) !u32 {
    const elem_ty = self.air.typeOfIndex(inst).elemType();

    if (!elem_ty.hasRuntimeBits()) {
        // As this stack item will never be dereferenced at runtime,
        // return the stack offset 0. Stack offset 0 will be where all
        // zero-sized stack allocations live as non-zero-sized
        // allocations will always have an offset > 0.
        return @as(u32, 0);
    }

    const abi_size = math.cast(u32, elem_ty.abiSize(self.target.*)) orelse {
        const mod = self.bin_file.options.module.?;
        return self.fail("type '{}' too big to fit into stack frame", .{elem_ty.fmt(mod)});
    };
    // TODO swap this for inst.ty.ptrAlign
    const abi_align = elem_ty.abiAlignment(self.target.*);
    return self.allocMem(inst, abi_size, abi_align);
}

fn allocRegOrMem(self: *Self, inst: Air.Inst.Index, reg_ok: bool) !MCValue {
    const elem_ty = self.air.typeOfIndex(inst);
    const abi_size = math.cast(u32, elem_ty.abiSize(self.target.*)) orelse {
        const mod = self.bin_file.options.module.?;
        return self.fail("type '{}' too big to fit into stack frame", .{elem_ty.fmt(mod)});
    };
    const abi_align = elem_ty.abiAlignment(self.target.*);
    if (abi_align > self.stack_align)
        self.stack_align = abi_align;

    if (reg_ok) {
        // Make sure the type can fit in a register before we try to allocate one.
        if (abi_size <= 8) {
            if (self.register_manager.tryAllocReg(inst, gp)) |reg| {
                return MCValue{ .register = reg };
            }
        }
    }
    const stack_offset = try self.allocMem(inst, abi_size, abi_align);
    return MCValue{ .stack_offset = stack_offset };
}

const BinOpMetadata = struct {
    inst: Air.Inst.Index,
    lhs: Air.Inst.Ref,
    rhs: Air.Inst.Ref,
};

/// For all your binary operation needs, this function will generate
/// the corresponding Mir instruction(s). Returns the location of the
/// result.
///
/// If the binary operation itself happens to be an Air instruction,
/// pass the corresponding index in the inst parameter. That helps
/// this function do stuff like reusing operands.
///
/// This function does not do any lowering to Mir itself, but instead
/// looks at the lhs and rhs and determines which kind of lowering
/// would be best suitable and then delegates the lowering to other
/// functions.
fn binOp(
    self: *Self,
    tag: Air.Inst.Tag,
    lhs: MCValue,
    rhs: MCValue,
    lhs_ty: Type,
    rhs_ty: Type,
    metadata: ?BinOpMetadata,
) InnerError!MCValue {
    const mod = self.bin_file.options.module.?;
    switch (tag) {
        .add, .cmp_eq => {
            switch (lhs_ty.zigTypeTag()) {
                .Float => return self.fail("TODO binary operations on floats", .{}),
                .Vector => return self.fail("TODO binary operations on vectors", .{}),
                .Int => {
                    assert(lhs_ty.eql(rhs_ty, mod));
                    const int_info = lhs_ty.intInfo(self.target.*);
                    if (int_info.bits <= 64) {
                        // Only say yes if the operation is
                        // commutative, i.e. we can swap both of the
                        // operands
                        const lhs_immediate_ok = switch (tag) {
                            .add => lhs == .immediate and lhs.immediate <= std.math.maxInt(u12),
                            .sub, .cmp_eq => false,
                            else => unreachable,
                        };
                        const rhs_immediate_ok = switch (tag) {
                            .add,
                            .sub,
                            .cmp_eq,
                            => rhs == .immediate and rhs.immediate <= std.math.maxInt(u12),
                            else => unreachable,
                        };

                        const mir_tag: Mir.Inst.Tag = switch (tag) {
                            .add => .add,
                            .cmp_eq => .cmp,
                            else => unreachable,
                        };

                        if (rhs_immediate_ok) {
                            return try self.binOpImmediate(mir_tag, lhs, rhs, lhs_ty, false, metadata);
                        } else if (lhs_immediate_ok) {
                            // swap lhs and rhs
                            return try self.binOpImmediate(mir_tag, rhs, lhs, rhs_ty, true, metadata);
                        } else {
                            // TODO convert large immediates to register before adding
                            return try self.binOpRegister(mir_tag, lhs, rhs, lhs_ty, rhs_ty, metadata);
                        }
                    } else {
                        return self.fail("TODO binary operations on int with bits > 64", .{});
                    }
                },
                else => unreachable,
            }
        },

        .mul => {
            switch (lhs_ty.zigTypeTag()) {
                .Vector => return self.fail("TODO binary operations on vectors", .{}),
                .Int => {
                    assert(lhs_ty.eql(rhs_ty, mod));
                    const int_info = lhs_ty.intInfo(self.target.*);
                    if (int_info.bits <= 64) {
                        // If LHS is immediate, then swap it with RHS.
                        const lhs_is_imm = lhs == .immediate;
                        const new_lhs = if (lhs_is_imm) rhs else lhs;
                        const new_rhs = if (lhs_is_imm) lhs else rhs;
                        const new_lhs_ty = if (lhs_is_imm) rhs_ty else lhs_ty;
                        const new_rhs_ty = if (lhs_is_imm) lhs_ty else rhs_ty;

                        // At this point, RHS might be an immediate
                        // If it's a power of two immediate then we emit an shl instead
                        // TODO add similar checks for LHS
                        if (new_rhs == .immediate and math.isPowerOfTwo(new_rhs.immediate)) {
                            return try self.binOp(.shl, new_lhs, .{ .immediate = math.log2(new_rhs.immediate) }, new_lhs_ty, Type.usize, metadata);
                        }

                        return try self.binOpRegister(.mulx, new_lhs, new_rhs, new_lhs_ty, new_rhs_ty, metadata);
                    } else {
                        return self.fail("TODO binary operations on int with bits > 64", .{});
                    }
                },
                else => unreachable,
            }
        },

        .ptr_add => {
            switch (lhs_ty.zigTypeTag()) {
                .Pointer => {
                    const ptr_ty = lhs_ty;
                    const elem_ty = switch (ptr_ty.ptrSize()) {
                        .One => ptr_ty.childType().childType(), // ptr to array, so get array element type
                        else => ptr_ty.childType(),
                    };
                    const elem_size = elem_ty.abiSize(self.target.*);

                    if (elem_size == 1) {
                        const base_tag: Mir.Inst.Tag = switch (tag) {
                            .ptr_add => .add,
                            else => unreachable,
                        };

                        return try self.binOpRegister(base_tag, lhs, rhs, lhs_ty, rhs_ty, metadata);
                    } else {
                        // convert the offset into a byte offset by
                        // multiplying it with elem_size

                        const offset = try self.binOp(.mul, rhs, .{ .immediate = elem_size }, Type.usize, Type.usize, null);
                        const addr = try self.binOp(tag, lhs, offset, Type.initTag(.manyptr_u8), Type.usize, null);
                        return addr;
                    }
                },
                else => unreachable,
            }
        },

        .shl => {
            const base_tag: Air.Inst.Tag = switch (tag) {
                .shl => .shl_exact,
                else => unreachable,
            };

            // Generate a shl_exact/shr_exact
            const result = try self.binOp(base_tag, lhs, rhs, lhs_ty, rhs_ty, metadata);

            // Truncate if necessary
            switch (tag) {
                .shl => switch (lhs_ty.zigTypeTag()) {
                    .Vector => return self.fail("TODO binary operations on vectors", .{}),
                    .Int => {
                        const int_info = lhs_ty.intInfo(self.target.*);
                        if (int_info.bits <= 64) {
                            const result_reg = result.register;
                            try self.truncRegister(result_reg, result_reg, int_info.signedness, int_info.bits);
                            return result;
                        } else {
                            return self.fail("TODO binary operations on integers > u64/i64", .{});
                        }
                    },
                    else => unreachable,
                },
                else => unreachable,
            }
        },

        .shl_exact => {
            switch (lhs_ty.zigTypeTag()) {
                .Vector => return self.fail("TODO binary operations on vectors", .{}),
                .Int => {
                    const int_info = lhs_ty.intInfo(self.target.*);
                    if (int_info.bits <= 64) {
                        const rhs_immediate_ok = rhs == .immediate;

                        const mir_tag: Mir.Inst.Tag = switch (tag) {
                            .shl_exact => .sllx,
                            else => unreachable,
                        };

                        if (rhs_immediate_ok) {
                            return try self.binOpImmediate(mir_tag, lhs, rhs, lhs_ty, false, metadata);
                        } else {
                            return try self.binOpRegister(mir_tag, lhs, rhs, lhs_ty, rhs_ty, metadata);
                        }
                    } else {
                        return self.fail("TODO binary operations on int with bits > 64", .{});
                    }
                },
                else => unreachable,
            }
        },

        else => return self.fail("TODO implement {} binOp for SPARCv9", .{tag}),
    }
}

/// Don't call this function directly. Use binOp instead.
///
/// Calling this function signals an intention to generate a Mir
/// instruction of the form
///
///     op dest, lhs, #rhs_imm
///
/// Set lhs_and_rhs_swapped to true iff inst.bin_op.lhs corresponds to
/// rhs and vice versa. This parameter is only used when metadata != null.
///
/// Asserts that generating an instruction of that form is possible.
fn binOpImmediate(
    self: *Self,
    mir_tag: Mir.Inst.Tag,
    lhs: MCValue,
    rhs: MCValue,
    lhs_ty: Type,
    lhs_and_rhs_swapped: bool,
    metadata: ?BinOpMetadata,
) !MCValue {
    const lhs_is_register = lhs == .register;

    const lhs_lock: ?RegisterLock = if (lhs_is_register)
        self.register_manager.lockReg(lhs.register)
    else
        null;
    defer if (lhs_lock) |reg| self.register_manager.unlockReg(reg);

    const branch = &self.branch_stack.items[self.branch_stack.items.len - 1];

    const lhs_reg = if (lhs_is_register) lhs.register else blk: {
        const track_inst: ?Air.Inst.Index = if (metadata) |md| inst: {
            break :inst Air.refToIndex(
                if (lhs_and_rhs_swapped) md.rhs else md.lhs,
            ).?;
        } else null;

        const reg = try self.register_manager.allocReg(track_inst, gp);

        if (track_inst) |inst| branch.inst_table.putAssumeCapacity(inst, .{ .register = reg });

        break :blk reg;
    };
    const new_lhs_lock = self.register_manager.lockReg(lhs_reg);
    defer if (new_lhs_lock) |reg| self.register_manager.unlockReg(reg);

    const dest_reg = switch (mir_tag) {
        else => if (metadata) |md| blk: {
            if (lhs_is_register and self.reuseOperand(
                md.inst,
                if (lhs_and_rhs_swapped) md.rhs else md.lhs,
                if (lhs_and_rhs_swapped) 1 else 0,
                lhs,
            )) {
                break :blk lhs_reg;
            } else {
                break :blk try self.register_manager.allocReg(md.inst, gp);
            }
        } else blk: {
            break :blk try self.register_manager.allocReg(null, gp);
        },
    };

    if (!lhs_is_register) try self.genSetReg(lhs_ty, lhs_reg, lhs);

    const mir_data: Mir.Inst.Data = switch (mir_tag) {
        .add,
        .mulx,
        .subcc,
        => .{
            .arithmetic_3op = .{
                .is_imm = true,
                .rd = dest_reg,
                .rs1 = lhs_reg,
                .rs2_or_imm = .{ .imm = @intCast(u12, rhs.immediate) },
            },
        },
        .sllx => .{
            .shift = .{
                .is_imm = true,
                .width = ShiftWidth.shift64,
                .rd = dest_reg,
                .rs1 = lhs_reg,
                .rs2_or_imm = .{ .imm = @intCast(u6, rhs.immediate) },
            },
        },
        .cmp => .{
            .arithmetic_2op = .{
                .is_imm = true,
                .rs1 = lhs_reg,
                .rs2_or_imm = .{ .imm = @intCast(u12, rhs.immediate) },
            },
        },
        else => unreachable,
    };

    _ = try self.addInst(.{
        .tag = mir_tag,
        .data = mir_data,
    });

    return MCValue{ .register = dest_reg };
}

/// Don't call this function directly. Use binOp instead.
///
/// Calling this function signals an intention to generate a Mir
/// instruction of the form
///
///     op dest, lhs, rhs
///
/// Asserts that generating an instruction of that form is possible.
fn binOpRegister(
    self: *Self,
    mir_tag: Mir.Inst.Tag,
    lhs: MCValue,
    rhs: MCValue,
    lhs_ty: Type,
    rhs_ty: Type,
    metadata: ?BinOpMetadata,
) !MCValue {
    const lhs_is_register = lhs == .register;
    const rhs_is_register = rhs == .register;

    const lhs_lock: ?RegisterLock = if (lhs_is_register)
        self.register_manager.lockReg(lhs.register)
    else
        null;
    defer if (lhs_lock) |reg| self.register_manager.unlockReg(reg);

    const rhs_lock: ?RegisterLock = if (rhs_is_register)
        self.register_manager.lockReg(rhs.register)
    else
        null;
    defer if (rhs_lock) |reg| self.register_manager.unlockReg(reg);

    const branch = &self.branch_stack.items[self.branch_stack.items.len - 1];

    const lhs_reg = if (lhs_is_register) lhs.register else blk: {
        const track_inst: ?Air.Inst.Index = if (metadata) |md| inst: {
            break :inst Air.refToIndex(md.lhs).?;
        } else null;

        const reg = try self.register_manager.allocReg(track_inst, gp);
        if (track_inst) |inst| branch.inst_table.putAssumeCapacity(inst, .{ .register = reg });

        break :blk reg;
    };
    const new_lhs_lock = self.register_manager.lockReg(lhs_reg);
    defer if (new_lhs_lock) |reg| self.register_manager.unlockReg(reg);

    const rhs_reg = if (rhs_is_register) rhs.register else blk: {
        const track_inst: ?Air.Inst.Index = if (metadata) |md| inst: {
            break :inst Air.refToIndex(md.rhs).?;
        } else null;

        const reg = try self.register_manager.allocReg(track_inst, gp);
        if (track_inst) |inst| branch.inst_table.putAssumeCapacity(inst, .{ .register = reg });

        break :blk reg;
    };
    const new_rhs_lock = self.register_manager.lockReg(rhs_reg);
    defer if (new_rhs_lock) |reg| self.register_manager.unlockReg(reg);

    const dest_reg = switch (mir_tag) {
        else => if (metadata) |md| blk: {
            if (lhs_is_register and self.reuseOperand(md.inst, md.lhs, 0, lhs)) {
                break :blk lhs_reg;
            } else if (rhs_is_register and self.reuseOperand(md.inst, md.rhs, 1, rhs)) {
                break :blk rhs_reg;
            } else {
                break :blk try self.register_manager.allocReg(md.inst, gp);
            }
        } else blk: {
            break :blk try self.register_manager.allocReg(null, gp);
        },
    };

    if (!lhs_is_register) try self.genSetReg(lhs_ty, lhs_reg, lhs);
    if (!rhs_is_register) try self.genSetReg(rhs_ty, rhs_reg, rhs);

    const mir_data: Mir.Inst.Data = switch (mir_tag) {
        .add,
        .mulx,
        .subcc,
        => .{
            .arithmetic_3op = .{
                .is_imm = false,
                .rd = dest_reg,
                .rs1 = lhs_reg,
                .rs2_or_imm = .{ .rs2 = rhs_reg },
            },
        },
        .sllx => .{
            .shift = .{
                .is_imm = false,
                .width = ShiftWidth.shift64,
                .rd = dest_reg,
                .rs1 = lhs_reg,
                .rs2_or_imm = .{ .rs2 = rhs_reg },
            },
        },
        .cmp => .{
            .arithmetic_2op = .{
                .is_imm = false,
                .rs1 = lhs_reg,
                .rs2_or_imm = .{ .rs2 = rhs_reg },
            },
        },
        else => unreachable,
    };

    _ = try self.addInst(.{
        .tag = mir_tag,
        .data = mir_data,
    });

    return MCValue{ .register = dest_reg };
}

fn br(self: *Self, block: Air.Inst.Index, operand: Air.Inst.Ref) !void {
    const block_data = self.blocks.getPtr(block).?;

    if (self.air.typeOf(operand).hasRuntimeBits()) {
        const operand_mcv = try self.resolveInst(operand);
        const block_mcv = block_data.mcv;
        if (block_mcv == .none) {
            block_data.mcv = switch (operand_mcv) {
                .none, .dead, .unreach => unreachable,
                .register, .stack_offset, .memory => operand_mcv,
                .immediate => blk: {
                    const new_mcv = try self.allocRegOrMem(block, true);
                    try self.setRegOrMem(self.air.typeOfIndex(block), new_mcv, operand_mcv);
                    break :blk new_mcv;
                },
                else => return self.fail("TODO implement block_data.mcv = operand_mcv for {}", .{operand_mcv}),
            };
        } else {
            try self.setRegOrMem(self.air.typeOfIndex(block), block_mcv, operand_mcv);
        }
    }
    return self.brVoid(block);
}

fn brVoid(self: *Self, block: Air.Inst.Index) !void {
    const block_data = self.blocks.getPtr(block).?;

    // Emit a jump with a relocation. It will be patched up after the block ends.
    try block_data.relocs.ensureUnusedCapacity(self.gpa, 1);

    const br_index = try self.addInst(.{
        .tag = .bpcc,
        .data = .{
            .branch_predict_int = .{
                .ccr = .xcc,
                .cond = .al,
                .inst = undefined, // Will be filled by performReloc
            },
        },
    });

    // TODO Find a way to fill this delay slot
    _ = try self.addInst(.{
        .tag = .nop,
        .data = .{ .nop = {} },
    });

    block_data.relocs.appendAssumeCapacity(br_index);
}

/// Copies a value to a register without tracking the register. The register is not considered
/// allocated. A second call to `copyToTmpRegister` may return the same register.
/// This can have a side effect of spilling instructions to the stack to free up a register.
fn copyToTmpRegister(self: *Self, ty: Type, mcv: MCValue) !Register {
    const reg = try self.register_manager.allocReg(null, gp);
    try self.genSetReg(ty, reg, mcv);
    return reg;
}

fn ensureProcessDeathCapacity(self: *Self, additional_count: usize) !void {
    const table = &self.branch_stack.items[self.branch_stack.items.len - 1].inst_table;
    try table.ensureUnusedCapacity(self.gpa, additional_count);
}

fn fail(self: *Self, comptime format: []const u8, args: anytype) InnerError {
    @setCold(true);
    assert(self.err_msg == null);
    self.err_msg = try ErrorMsg.create(self.bin_file.allocator, self.src_loc, format, args);
    return error.CodegenFail;
}

/// Called when there are no operands, and the instruction is always unreferenced.
fn finishAirBookkeeping(self: *Self) void {
    if (std.debug.runtime_safety) {
        self.air_bookkeeping += 1;
    }
}

fn finishAir(self: *Self, inst: Air.Inst.Index, result: MCValue, operands: [Liveness.bpi - 1]Air.Inst.Ref) void {
    var tomb_bits = self.liveness.getTombBits(inst);
    for (operands) |op| {
        const dies = @truncate(u1, tomb_bits) != 0;
        tomb_bits >>= 1;
        if (!dies) continue;
        const op_int = @enumToInt(op);
        if (op_int < Air.Inst.Ref.typed_value_map.len) continue;
        const op_index = @intCast(Air.Inst.Index, op_int - Air.Inst.Ref.typed_value_map.len);
        self.processDeath(op_index);
    }
    const is_used = @truncate(u1, tomb_bits) == 0;
    if (is_used) {
        log.debug("%{d} => {}", .{ inst, result });
        const branch = &self.branch_stack.items[self.branch_stack.items.len - 1];
        branch.inst_table.putAssumeCapacityNoClobber(inst, result);

        switch (result) {
            .register => |reg| {
                // In some cases (such as bitcast), an operand
                // may be the same MCValue as the result. If
                // that operand died and was a register, it
                // was freed by processDeath. We have to
                // "re-allocate" the register.
                if (self.register_manager.isRegFree(reg)) {
                    self.register_manager.getRegAssumeFree(reg, inst);
                }
            },
            else => {},
        }
    }
    self.finishAirBookkeeping();
}

fn genArgDbgInfo(self: *Self, inst: Air.Inst.Index, mcv: MCValue, arg_index: u32) !void {
    const ty = self.air.instructions.items(.data)[inst].ty;
    const name = self.mod_fn.getParamName(arg_index);
    const name_with_null = name.ptr[0 .. name.len + 1];

    switch (mcv) {
        .register => |reg| {
            switch (self.debug_output) {
                .dwarf => |dw| {
                    const dbg_info = &dw.dbg_info;
                    try dbg_info.ensureUnusedCapacity(3);
                    dbg_info.appendAssumeCapacity(@enumToInt(link.File.Dwarf.AbbrevKind.parameter));
                    dbg_info.appendSliceAssumeCapacity(&[2]u8{ // DW.AT.location, DW.FORM.exprloc
                        1, // ULEB128 dwarf expression length
                        reg.dwarfLocOp(),
                    });
                    try dbg_info.ensureUnusedCapacity(5 + name_with_null.len);
                    try self.addDbgInfoTypeReloc(ty); // DW.AT.type,  DW.FORM.ref4
                    dbg_info.appendSliceAssumeCapacity(name_with_null); // DW.AT.name, DW.FORM.string
                },
                else => {},
            }
        },
        .stack_offset => |offset| {
            _ = offset;
            switch (self.debug_output) {
                .dwarf => {},
                else => {},
            }
        },
        else => {},
    }
}

// TODO replace this to call to extern memcpy
fn genInlineMemcpy(
    self: *Self,
    src: Register,
    dst: Register,
    len: Register,
    tmp: Register,
) !void {
    // Here we assume that len > 0.
    // Also we do the copy from end -> start address to save a register.

    // sub len, 1, len
    _ = try self.addInst(.{
        .tag = .sub,
        .data = .{ .arithmetic_3op = .{
            .is_imm = true,
            .rs1 = len,
            .rs2_or_imm = .{ .imm = 1 },
            .rd = len,
        } },
    });

    // loop:
    // ldub [src + len], tmp
    _ = try self.addInst(.{
        .tag = .ldub,
        .data = .{ .arithmetic_3op = .{
            .is_imm = false,
            .rs1 = src,
            .rs2_or_imm = .{ .rs2 = len },
            .rd = tmp,
        } },
    });

    // stb tmp, [dst + len]
    _ = try self.addInst(.{
        .tag = .stb,
        .data = .{ .arithmetic_3op = .{
            .is_imm = false,
            .rs1 = dst,
            .rs2_or_imm = .{ .rs2 = len },
            .rd = tmp,
        } },
    });

    // brnz len, loop
    _ = try self.addInst(.{
        .tag = .bpr,
        .data = .{ .branch_predict_reg = .{
            .cond = .ne_zero,
            .rs1 = len,
            .inst = @intCast(u32, self.mir_instructions.len - 2),
        } },
    });

    // Delay slot:
    //  sub len, 1, len
    _ = try self.addInst(.{
        .tag = .sub,
        .data = .{ .arithmetic_3op = .{
            .is_imm = true,
            .rs1 = len,
            .rs2_or_imm = .{ .imm = 1 },
            .rd = len,
        } },
    });

    // end:
}

fn genLoad(self: *Self, value_reg: Register, addr_reg: Register, comptime off_type: type, off: off_type, abi_size: u64) !void {
    assert(off_type == Register or off_type == i13);

    const is_imm = (off_type == i13);
    const rs2_or_imm = if (is_imm) .{ .imm = off } else .{ .rs2 = off };

    switch (abi_size) {
        1, 2, 4, 8 => {
            const tag: Mir.Inst.Tag = switch (abi_size) {
                1 => .ldub,
                2 => .lduh,
                4 => .lduw,
                8 => .ldx,
                else => unreachable, // unexpected abi size
            };

            _ = try self.addInst(.{
                .tag = tag,
                .data = .{
                    .arithmetic_3op = .{
                        .is_imm = is_imm,
                        .rd = value_reg,
                        .rs1 = addr_reg,
                        .rs2_or_imm = rs2_or_imm,
                    },
                },
            });
        },
        3, 5, 6, 7 => return self.fail("TODO: genLoad for more abi_sizes", .{}),
        else => unreachable,
    }
}

fn genSetReg(self: *Self, ty: Type, reg: Register, mcv: MCValue) InnerError!void {
    switch (mcv) {
        .dead => unreachable,
        .unreach, .none => return, // Nothing to do.
        .compare_flags_signed,
        .compare_flags_unsigned,
        => {
            const condition = switch (mcv) {
                .compare_flags_unsigned => |op| Instruction.ICondition.fromCompareOperatorUnsigned(op.cmp),
                .compare_flags_signed => |op| Instruction.ICondition.fromCompareOperatorSigned(op.cmp),
                else => unreachable,
            };

            const ccr = switch (mcv) {
                .compare_flags_unsigned => |op| op.ccr,
                .compare_flags_signed => |op| op.ccr,
                else => unreachable,
            };
            // TODO handle floating point CCRs
            assert(ccr == .xcc or ccr == .icc);

            _ = try self.addInst(.{
                .tag = .mov,
                .data = .{
                    .arithmetic_2op = .{
                        .is_imm = false,
                        .rs1 = reg,
                        .rs2_or_imm = .{ .rs2 = .g0 },
                    },
                },
            });

            _ = try self.addInst(.{
                .tag = .movcc,
                .data = .{
                    .conditional_move = .{
                        .ccr = ccr,
                        .cond = .{ .icond = condition },
                        .is_imm = true,
                        .rd = reg,
                        .rs2_or_imm = .{ .imm = 1 },
                    },
                },
            });
        },
        .undef => {
            if (!self.wantSafety())
                return; // The already existing value will do just fine.
            // Write the debug undefined value.
            return self.genSetReg(ty, reg, .{ .immediate = 0xaaaaaaaaaaaaaaaa });
        },
        .ptr_stack_offset => |off| {
            const simm13 = math.cast(u12, off + abi.stack_bias + abi.stack_reserved_area) orelse
                return self.fail("TODO larger stack offsets", .{});

            _ = try self.addInst(.{
                .tag = .add,
                .data = .{
                    .arithmetic_3op = .{
                        .is_imm = true,
                        .rd = reg,
                        .rs1 = .sp,
                        .rs2_or_imm = .{ .imm = simm13 },
                    },
                },
            });
        },
        .immediate => |x| {
            if (x <= math.maxInt(u12)) {
                _ = try self.addInst(.{
                    .tag = .mov,
                    .data = .{
                        .arithmetic_2op = .{
                            .is_imm = true,
                            .rs1 = reg,
                            .rs2_or_imm = .{ .imm = @truncate(u12, x) },
                        },
                    },
                });
            } else if (x <= math.maxInt(u32)) {
                _ = try self.addInst(.{
                    .tag = .sethi,
                    .data = .{
                        .sethi = .{
                            .rd = reg,
                            .imm = @truncate(u22, x >> 10),
                        },
                    },
                });

                _ = try self.addInst(.{
                    .tag = .@"or",
                    .data = .{
                        .arithmetic_3op = .{
                            .is_imm = true,
                            .rd = reg,
                            .rs1 = reg,
                            .rs2_or_imm = .{ .imm = @truncate(u10, x) },
                        },
                    },
                });
            } else if (x <= math.maxInt(u44)) {
                try self.genSetReg(ty, reg, .{ .immediate = @truncate(u32, x >> 12) });

                _ = try self.addInst(.{
                    .tag = .sllx,
                    .data = .{
                        .shift = .{
                            .is_imm = true,
                            .width = .shift64,
                            .rd = reg,
                            .rs1 = reg,
                            .rs2_or_imm = .{ .imm = 12 },
                        },
                    },
                });

                _ = try self.addInst(.{
                    .tag = .@"or",
                    .data = .{
                        .arithmetic_3op = .{
                            .is_imm = true,
                            .rd = reg,
                            .rs1 = reg,
                            .rs2_or_imm = .{ .imm = @truncate(u12, x) },
                        },
                    },
                });
            } else {
                // Need to allocate a temporary register to load 64-bit immediates.
                const tmp_reg = try self.register_manager.allocReg(null, gp);

                try self.genSetReg(ty, tmp_reg, .{ .immediate = @truncate(u32, x) });
                try self.genSetReg(ty, reg, .{ .immediate = @truncate(u32, x >> 32) });

                _ = try self.addInst(.{
                    .tag = .sllx,
                    .data = .{
                        .shift = .{
                            .is_imm = true,
                            .width = .shift64,
                            .rd = reg,
                            .rs1 = reg,
                            .rs2_or_imm = .{ .imm = 32 },
                        },
                    },
                });

                _ = try self.addInst(.{
                    .tag = .@"or",
                    .data = .{
                        .arithmetic_3op = .{
                            .is_imm = false,
                            .rd = reg,
                            .rs1 = reg,
                            .rs2_or_imm = .{ .rs2 = tmp_reg },
                        },
                    },
                });
            }
        },
        .register => |src_reg| {
            // If the registers are the same, nothing to do.
            if (src_reg.id() == reg.id())
                return;

            _ = try self.addInst(.{
                .tag = .mov,
                .data = .{
                    .arithmetic_2op = .{
                        .is_imm = false,
                        .rs1 = reg,
                        .rs2_or_imm = .{ .rs2 = src_reg },
                    },
                },
            });
        },
        .memory => |addr| {
            // The value is in memory at a hard-coded address.
            // If the type is a pointer, it means the pointer address is at this memory location.
            try self.genSetReg(ty, reg, .{ .immediate = addr });
            try self.genLoad(reg, reg, i13, 0, ty.abiSize(self.target.*));
        },
        .stack_offset => |off| {
            const real_offset = off + abi.stack_bias + abi.stack_reserved_area;
            const simm13 = math.cast(i13, real_offset) orelse
                return self.fail("TODO larger stack offsets", .{});
            try self.genLoad(reg, .sp, i13, simm13, ty.abiSize(self.target.*));
        },
    }
}

fn genSetStack(self: *Self, ty: Type, stack_offset: u32, mcv: MCValue) InnerError!void {
    const abi_size = ty.abiSize(self.target.*);
    switch (mcv) {
        .dead => unreachable,
        .unreach, .none => return, // Nothing to do.
        .undef => {
            if (!self.wantSafety())
                return; // The already existing value will do just fine.
            // TODO Upgrade this to a memset call when we have that available.
            switch (ty.abiSize(self.target.*)) {
                1 => return self.genSetStack(ty, stack_offset, .{ .immediate = 0xaa }),
                2 => return self.genSetStack(ty, stack_offset, .{ .immediate = 0xaaaa }),
                4 => return self.genSetStack(ty, stack_offset, .{ .immediate = 0xaaaaaaaa }),
                8 => return self.genSetStack(ty, stack_offset, .{ .immediate = 0xaaaaaaaaaaaaaaaa }),
                else => return self.fail("TODO implement memset", .{}),
            }
        },
        .compare_flags_unsigned,
        .compare_flags_signed,
        .immediate,
        .ptr_stack_offset,
        => {
            const reg = try self.copyToTmpRegister(ty, mcv);
            return self.genSetStack(ty, stack_offset, MCValue{ .register = reg });
        },
        .register => |reg| {
            const real_offset = stack_offset + abi.stack_bias + abi.stack_reserved_area;
            const simm13 = math.cast(i13, real_offset) orelse
                return self.fail("TODO larger stack offsets", .{});
            return self.genStore(reg, .sp, i13, simm13, abi_size);
        },
        .memory, .stack_offset => {
            switch (mcv) {
                .stack_offset => |off| {
                    if (stack_offset == off)
                        return; // Copy stack variable to itself; nothing to do.
                },
                else => {},
            }

            if (abi_size <= 8) {
                const reg = try self.copyToTmpRegister(ty, mcv);
                return self.genSetStack(ty, stack_offset, MCValue{ .register = reg });
            } else {
                var ptr_ty_payload: Type.Payload.ElemType = .{
                    .base = .{ .tag = .single_mut_pointer },
                    .data = ty,
                };
                const ptr_ty = Type.initPayload(&ptr_ty_payload.base);

                const regs = try self.register_manager.allocRegs(4, .{ null, null, null, null }, gp);
                const regs_locks = self.register_manager.lockRegsAssumeUnused(4, regs);
                defer for (regs_locks) |reg| {
                    self.register_manager.unlockReg(reg);
                };

                const src_reg = regs[0];
                const dst_reg = regs[1];
                const len_reg = regs[2];
                const tmp_reg = regs[3];

                switch (mcv) {
                    .stack_offset => |off| try self.genSetReg(ptr_ty, src_reg, .{ .ptr_stack_offset = off }),
                    .memory => |addr| try self.genSetReg(Type.usize, src_reg, .{ .immediate = addr }),
                    else => unreachable,
                }

                try self.genSetReg(ptr_ty, dst_reg, .{ .ptr_stack_offset = stack_offset });
                try self.genSetReg(Type.usize, len_reg, .{ .immediate = abi_size });
                try self.genInlineMemcpy(src_reg, dst_reg, len_reg, tmp_reg);
            }
        },
    }
}

fn genStore(self: *Self, value_reg: Register, addr_reg: Register, comptime off_type: type, off: off_type, abi_size: u64) !void {
    assert(off_type == Register or off_type == i13);

    const is_imm = (off_type == i13);
    const rs2_or_imm = if (is_imm) .{ .imm = off } else .{ .rs2 = off };

    switch (abi_size) {
        1, 2, 4, 8 => {
            const tag: Mir.Inst.Tag = switch (abi_size) {
                1 => .stb,
                2 => .sth,
                4 => .stw,
                8 => .stx,
                else => unreachable, // unexpected abi size
            };

            _ = try self.addInst(.{
                .tag = tag,
                .data = .{
                    .arithmetic_3op = .{
                        .is_imm = is_imm,
                        .rd = value_reg,
                        .rs1 = addr_reg,
                        .rs2_or_imm = rs2_or_imm,
                    },
                },
            });
        },
        3, 5, 6, 7 => return self.fail("TODO: genLoad for more abi_sizes", .{}),
        else => unreachable,
    }
}

fn genTypedValue(self: *Self, typed_value: TypedValue) InnerError!MCValue {
    if (typed_value.val.isUndef())
        return MCValue{ .undef = {} };

    if (typed_value.val.castTag(.decl_ref)) |payload| {
        return self.lowerDeclRef(typed_value, payload.data);
    }
    if (typed_value.val.castTag(.decl_ref_mut)) |payload| {
        return self.lowerDeclRef(typed_value, payload.data.decl_index);
    }
    const target = self.target.*;

    switch (typed_value.ty.zigTypeTag()) {
        .Int => {
            const info = typed_value.ty.intInfo(self.target.*);
            if (info.bits <= 64) {
                const unsigned = switch (info.signedness) {
                    .signed => blk: {
                        const signed = typed_value.val.toSignedInt();
                        break :blk @bitCast(u64, signed);
                    },
                    .unsigned => typed_value.val.toUnsignedInt(target),
                };

                return MCValue{ .immediate = unsigned };
            } else {
                return self.fail("TODO implement int genTypedValue of > 64 bits", .{});
            }
        },
        .ErrorSet => {
            const err_name = typed_value.val.castTag(.@"error").?.data.name;
            const module = self.bin_file.options.module.?;
            const global_error_set = module.global_error_set;
            const error_index = global_error_set.get(err_name).?;
            return MCValue{ .immediate = error_index };
        },
        .ErrorUnion => {
            const error_type = typed_value.ty.errorUnionSet();
            const payload_type = typed_value.ty.errorUnionPayload();

            if (typed_value.val.castTag(.eu_payload)) |pl| {
                if (!payload_type.hasRuntimeBits()) {
                    // We use the error type directly as the type.
                    return MCValue{ .immediate = 0 };
                }

                _ = pl;
                return self.fail("TODO implement error union const of type '{}' (non-error)", .{typed_value.ty.fmtDebug()});
            } else {
                if (!payload_type.hasRuntimeBits()) {
                    // We use the error type directly as the type.
                    return self.genTypedValue(.{ .ty = error_type, .val = typed_value.val });
                }

                return self.fail("TODO implement error union const of type '{}' (error)", .{typed_value.ty.fmtDebug()});
            }
        },
        .ComptimeInt => unreachable, // semantic analysis prevents this
        .ComptimeFloat => unreachable, // semantic analysis prevents this
        else => return self.fail("TODO implement const of type '{}'", .{typed_value.ty.fmtDebug()}),
    }
}

fn getResolvedInstValue(self: *Self, inst: Air.Inst.Index) MCValue {
    // Treat each stack item as a "layer" on top of the previous one.
    var i: usize = self.branch_stack.items.len;
    while (true) {
        i -= 1;
        if (self.branch_stack.items[i].inst_table.get(inst)) |mcv| {
            assert(mcv != .dead);
            return mcv;
        }
    }
}

fn isErr(self: *Self, ty: Type, operand: MCValue) !MCValue {
    const error_type = ty.errorUnionSet();
    const payload_type = ty.errorUnionPayload();

    if (!error_type.hasRuntimeBits()) {
        return MCValue{ .immediate = 0 }; // always false
    } else if (!payload_type.hasRuntimeBits()) {
        if (error_type.abiSize(self.target.*) <= 8) {
            const reg_mcv: MCValue = switch (operand) {
                .register => operand,
                else => .{ .register = try self.copyToTmpRegister(error_type, operand) },
            };

            _ = try self.addInst(.{
                .tag = .cmp,
                .data = .{ .arithmetic_2op = .{
                    .is_imm = true,
                    .rs1 = reg_mcv.register,
                    .rs2_or_imm = .{ .imm = 0 },
                } },
            });

            return MCValue{ .compare_flags_unsigned = .{ .cmp = .gt, .ccr = .xcc } };
        } else {
            return self.fail("TODO isErr for errors with size > 8", .{});
        }
    } else {
        return self.fail("TODO isErr for non-empty payloads", .{});
    }
}

fn isNonErr(self: *Self, ty: Type, operand: MCValue) !MCValue {
    // Call isErr, then negate the result.
    const is_err_result = try self.isErr(ty, operand);
    switch (is_err_result) {
        .compare_flags_unsigned => |op| {
            assert(op.cmp == .gt);
            return MCValue{ .compare_flags_unsigned = .{ .cmp = .gt, .ccr = op.ccr } };
        },
        .immediate => |imm| {
            assert(imm == 0);
            return MCValue{ .immediate = 1 };
        },
        else => unreachable,
    }
}

fn iterateBigTomb(self: *Self, inst: Air.Inst.Index, operand_count: usize) !BigTomb {
    try self.ensureProcessDeathCapacity(operand_count + 1);
    return BigTomb{
        .function = self,
        .inst = inst,
        .tomb_bits = self.liveness.getTombBits(inst),
        .big_tomb_bits = self.liveness.special.get(inst) orelse 0,
        .bit_index = 0,
    };
}

/// Send control flow to `inst`.
fn jump(self: *Self, inst: Mir.Inst.Index) !void {
    _ = try self.addInst(.{
        .tag = .bpcc,
        .data = .{
            .branch_predict_int = .{
                .cond = .al,
                .ccr = .xcc,
                .inst = inst,
            },
        },
    });

    // TODO find out a way to fill this delay slot
    _ = try self.addInst(.{
        .tag = .nop,
        .data = .{ .nop = {} },
    });
}

fn load(self: *Self, dst_mcv: MCValue, ptr: MCValue, ptr_ty: Type) InnerError!void {
    const elem_ty = ptr_ty.elemType();
    const elem_size = elem_ty.abiSize(self.target.*);

    switch (ptr) {
        .none => unreachable,
        .undef => unreachable,
        .unreach => unreachable,
        .dead => unreachable,
        .compare_flags_unsigned,
        .compare_flags_signed,
        => unreachable, // cannot hold an address
        .immediate => |imm| try self.setRegOrMem(elem_ty, dst_mcv, .{ .memory = imm }),
        .ptr_stack_offset => |off| try self.setRegOrMem(elem_ty, dst_mcv, .{ .stack_offset = off }),
        .register => |addr_reg| {
            const addr_reg_lock = self.register_manager.lockReg(addr_reg);
            defer if (addr_reg_lock) |reg| self.register_manager.unlockReg(reg);

            switch (dst_mcv) {
                .dead => unreachable,
                .undef => unreachable,
                .compare_flags_signed, .compare_flags_unsigned => unreachable,
                .register => |dst_reg| {
                    try self.genLoad(dst_reg, addr_reg, i13, 0, elem_size);
                },
                .stack_offset => |off| {
                    if (elem_size <= 8) {
                        const tmp_reg = try self.register_manager.allocReg(null, gp);
                        const tmp_reg_lock = self.register_manager.lockRegAssumeUnused(tmp_reg);
                        defer self.register_manager.unlockReg(tmp_reg_lock);

                        try self.load(.{ .register = tmp_reg }, ptr, ptr_ty);
                        try self.genSetStack(elem_ty, off, MCValue{ .register = tmp_reg });
                    } else {
                        const regs = try self.register_manager.allocRegs(3, .{ null, null, null }, gp);
                        const regs_locks = self.register_manager.lockRegsAssumeUnused(3, regs);
                        defer for (regs_locks) |reg| {
                            self.register_manager.unlockReg(reg);
                        };

                        const src_reg = addr_reg;
                        const dst_reg = regs[0];
                        const len_reg = regs[1];
                        const tmp_reg = regs[2];

                        try self.genSetReg(ptr_ty, dst_reg, .{ .ptr_stack_offset = off });
                        try self.genSetReg(Type.usize, len_reg, .{ .immediate = elem_size });
                        try self.genInlineMemcpy(src_reg, dst_reg, len_reg, tmp_reg);
                    }
                },
                else => return self.fail("TODO load from register into {}", .{dst_mcv}),
            }
        },
        .memory,
        .stack_offset,
        => {
            const addr_reg = try self.copyToTmpRegister(ptr_ty, ptr);
            try self.load(dst_mcv, .{ .register = addr_reg }, ptr_ty);
        },
    }
}

fn lowerDeclRef(self: *Self, tv: TypedValue, decl_index: Module.Decl.Index) InnerError!MCValue {
    const ptr_bits = self.target.cpu.arch.ptrBitWidth();
    const ptr_bytes: u64 = @divExact(ptr_bits, 8);

    // TODO this feels clunky. Perhaps we should check for it in `genTypedValue`?
    if (tv.ty.zigTypeTag() == .Pointer) blk: {
        if (tv.ty.castPtrToFn()) |_| break :blk;
        if (!tv.ty.elemType2().hasRuntimeBits()) {
            return MCValue.none;
        }
    }

    const mod = self.bin_file.options.module.?;
    const decl = mod.declPtr(decl_index);

    mod.markDeclAlive(decl);
    if (self.bin_file.cast(link.File.Elf)) |elf_file| {
        const got = &elf_file.program_headers.items[elf_file.phdr_got_index.?];
        const got_addr = got.p_vaddr + decl.link.elf.offset_table_index * ptr_bytes;
        return MCValue{ .memory = got_addr };
    } else {
        return self.fail("TODO codegen non-ELF const Decl pointer", .{});
    }
}

fn parseRegName(name: []const u8) ?Register {
    if (@hasDecl(Register, "parseRegName")) {
        return Register.parseRegName(name);
    }
    return std.meta.stringToEnum(Register, name);
}

fn performReloc(self: *Self, inst: Mir.Inst.Index) !void {
    const tag = self.mir_instructions.items(.tag)[inst];
    switch (tag) {
        .bpcc => self.mir_instructions.items(.data)[inst].branch_predict_int.inst = @intCast(Mir.Inst.Index, self.mir_instructions.len),
        else => unreachable,
    }
}

/// Asserts there is already capacity to insert into top branch inst_table.
fn processDeath(self: *Self, inst: Air.Inst.Index) void {
    const air_tags = self.air.instructions.items(.tag);
    if (air_tags[inst] == .constant) return; // Constants are immortal.
    // When editing this function, note that the logic must synchronize with `reuseOperand`.
    const prev_value = self.getResolvedInstValue(inst);
    const branch = &self.branch_stack.items[self.branch_stack.items.len - 1];
    branch.inst_table.putAssumeCapacity(inst, .dead);
    switch (prev_value) {
        .register => |reg| {
            self.register_manager.freeReg(reg);
        },
        .compare_flags_signed, .compare_flags_unsigned => {
            self.compare_flags_inst = null;
        },
        else => {}, // TODO process stack allocation death
    }
}

/// Caller must call `CallMCValues.deinit`.
fn resolveCallingConventionValues(self: *Self, fn_ty: Type, role: RegisterView) !CallMCValues {
    const cc = fn_ty.fnCallingConvention();
    const param_types = try self.gpa.alloc(Type, fn_ty.fnParamLen());
    defer self.gpa.free(param_types);
    fn_ty.fnParamTypes(param_types);
    var result: CallMCValues = .{
        .args = try self.gpa.alloc(MCValue, param_types.len),
        // These undefined values must be populated before returning from this function.
        .return_value = undefined,
        .stack_byte_count = undefined,
        .stack_align = undefined,
    };
    errdefer self.gpa.free(result.args);

    const ret_ty = fn_ty.fnReturnType();

    switch (cc) {
        .Naked => {
            assert(result.args.len == 0);
            result.return_value = .{ .unreach = {} };
            result.stack_byte_count = 0;
            result.stack_align = 1;
            return result;
        },
        .Unspecified, .C => {
            // SPARC Compliance Definition 2.4.1, Chapter 3
            // Low-Level System Information (64-bit psABI) - Function Calling Sequence

            var next_register: usize = 0;
            var next_stack_offset: u32 = 0;

            // The caller puts the argument in %o0-%o5, which becomes %i0-%i5 inside the callee.
            const argument_registers = switch (role) {
                .caller => abi.c_abi_int_param_regs_caller_view,
                .callee => abi.c_abi_int_param_regs_callee_view,
            };

            for (param_types) |ty, i| {
                const param_size = @intCast(u32, ty.abiSize(self.target.*));
                if (param_size <= 8) {
                    if (next_register < argument_registers.len) {
                        result.args[i] = .{ .register = argument_registers[next_register] };
                        next_register += 1;
                    } else {
                        result.args[i] = .{ .stack_offset = next_stack_offset };
                        next_register += next_stack_offset;
                    }
                } else if (param_size <= 16) {
                    if (next_register < argument_registers.len - 1) {
                        return self.fail("TODO MCValues with 2 registers", .{});
                    } else if (next_register < argument_registers.len) {
                        return self.fail("TODO MCValues split register + stack", .{});
                    } else {
                        result.args[i] = .{ .stack_offset = next_stack_offset };
                        next_register += next_stack_offset;
                    }
                } else {
                    result.args[i] = .{ .stack_offset = next_stack_offset };
                    next_register += next_stack_offset;
                }
            }

            result.stack_byte_count = next_stack_offset;
            result.stack_align = 16;

            if (ret_ty.zigTypeTag() == .NoReturn) {
                result.return_value = .{ .unreach = {} };
            } else if (!ret_ty.hasRuntimeBits()) {
                result.return_value = .{ .none = {} };
            } else {
                const ret_ty_size = @intCast(u32, ret_ty.abiSize(self.target.*));
                // The callee puts the return values in %i0-%i3, which becomes %o0-%o3 inside the caller.
                if (ret_ty_size <= 8) {
                    result.return_value = switch (role) {
                        .caller => .{ .register = abi.c_abi_int_return_regs_caller_view[0] },
                        .callee => .{ .register = abi.c_abi_int_return_regs_callee_view[0] },
                    };
                } else {
                    return self.fail("TODO support more return values for sparc64", .{});
                }
            }
        },
        else => return self.fail("TODO implement function parameters for {} on sparc64", .{cc}),
    }

    return result;
}

fn resolveInst(self: *Self, inst: Air.Inst.Ref) InnerError!MCValue {
    // First section of indexes correspond to a set number of constant values.
    const ref_int = @enumToInt(inst);
    if (ref_int < Air.Inst.Ref.typed_value_map.len) {
        const tv = Air.Inst.Ref.typed_value_map[ref_int];
        if (!tv.ty.hasRuntimeBits()) {
            return MCValue{ .none = {} };
        }
        return self.genTypedValue(tv);
    }

    // If the type has no codegen bits, no need to store it.
    const inst_ty = self.air.typeOf(inst);
    if (!inst_ty.hasRuntimeBits())
        return MCValue{ .none = {} };

    const inst_index = @intCast(Air.Inst.Index, ref_int - Air.Inst.Ref.typed_value_map.len);
    switch (self.air.instructions.items(.tag)[inst_index]) {
        .constant => {
            // Constants have static lifetimes, so they are always memoized in the outer most table.
            const branch = &self.branch_stack.items[0];
            const gop = try branch.inst_table.getOrPut(self.gpa, inst_index);
            if (!gop.found_existing) {
                const ty_pl = self.air.instructions.items(.data)[inst_index].ty_pl;
                gop.value_ptr.* = try self.genTypedValue(.{
                    .ty = inst_ty,
                    .val = self.air.values[ty_pl.payload],
                });
            }
            return gop.value_ptr.*;
        },
        .const_ty => unreachable,
        else => return self.getResolvedInstValue(inst_index),
    }
}

fn ret(self: *Self, mcv: MCValue) !void {
    const ret_ty = self.fn_type.fnReturnType();
    try self.setRegOrMem(ret_ty, self.ret_mcv, mcv);

    // Just add space for a branch instruction, patch this later
    const index = try self.addInst(.{
        .tag = .nop,
        .data = .{ .nop = {} },
    });

    // Reserve space for the delay slot too
    // TODO find out a way to fill this
    _ = try self.addInst(.{
        .tag = .nop,
        .data = .{ .nop = {} },
    });
    try self.exitlude_jump_relocs.append(self.gpa, index);
}

fn reuseOperand(self: *Self, inst: Air.Inst.Index, operand: Air.Inst.Ref, op_index: Liveness.OperandInt, mcv: MCValue) bool {
    if (!self.liveness.operandDies(inst, op_index))
        return false;

    switch (mcv) {
        .register => |reg| {
            // If it's in the registers table, need to associate the register with the
            // new instruction.
            if (RegisterManager.indexOfRegIntoTracked(reg)) |index| {
                if (!self.register_manager.isRegFree(reg)) {
                    self.register_manager.registers[index] = inst;
                }
            }
            log.debug("%{d} => {} (reused)", .{ inst, reg });
        },
        .stack_offset => |off| {
            log.debug("%{d} => stack offset {d} (reused)", .{ inst, off });
        },
        else => return false,
    }

    // Prevent the operand deaths processing code from deallocating it.
    self.liveness.clearOperandDeath(inst, op_index);

    // That makes us responsible for doing the rest of the stuff that processDeath would have done.
    const branch = &self.branch_stack.items[self.branch_stack.items.len - 1];
    branch.inst_table.putAssumeCapacity(Air.refToIndex(operand).?, .dead);

    return true;
}

/// Sets the value without any modifications to register allocation metadata or stack allocation metadata.
fn setRegOrMem(self: *Self, ty: Type, loc: MCValue, val: MCValue) !void {
    switch (loc) {
        .none => return,
        .register => |reg| return self.genSetReg(ty, reg, val),
        .stack_offset => |off| return self.genSetStack(ty, off, val),
        .memory => {
            return self.fail("TODO implement setRegOrMem for memory", .{});
        },
        else => unreachable,
    }
}

/// Save the current instruction stored in the compare flags if
/// occupied
fn spillCompareFlagsIfOccupied(self: *Self) !void {
    if (self.compare_flags_inst) |inst_to_save| {
        const mcv = self.getResolvedInstValue(inst_to_save);
        const new_mcv = switch (mcv) {
            .compare_flags_signed,
            .compare_flags_unsigned,
            => try self.allocRegOrMem(inst_to_save, true),
            else => unreachable, // mcv doesn't occupy the compare flags
        };

        try self.setRegOrMem(self.air.typeOfIndex(inst_to_save), new_mcv, mcv);
        log.debug("spilling {d} to mcv {any}", .{ inst_to_save, new_mcv });

        const branch = &self.branch_stack.items[self.branch_stack.items.len - 1];
        try branch.inst_table.put(self.gpa, inst_to_save, new_mcv);

        self.compare_flags_inst = null;
    }
}

pub fn spillInstruction(self: *Self, reg: Register, inst: Air.Inst.Index) !void {
    const stack_mcv = try self.allocRegOrMem(inst, false);
    log.debug("spilling {d} to stack mcv {any}", .{ inst, stack_mcv });
    const reg_mcv = self.getResolvedInstValue(inst);
    assert(reg == reg_mcv.register);
    const branch = &self.branch_stack.items[self.branch_stack.items.len - 1];
    try branch.inst_table.put(self.gpa, inst, stack_mcv);
    try self.genSetStack(self.air.typeOfIndex(inst), stack_mcv.stack_offset, reg_mcv);
}

fn store(self: *Self, ptr: MCValue, value: MCValue, ptr_ty: Type, value_ty: Type) InnerError!void {
    const abi_size = value_ty.abiSize(self.target.*);

    switch (ptr) {
        .none => unreachable,
        .undef => unreachable,
        .unreach => unreachable,
        .dead => unreachable,
        .compare_flags_unsigned,
        .compare_flags_signed,
        => unreachable, // cannot hold an address
        .immediate => |imm| {
            try self.setRegOrMem(value_ty, .{ .memory = imm }, value);
        },
        .ptr_stack_offset => |off| {
            try self.genSetStack(value_ty, off, value);
        },
        .register => |addr_reg| {
            const addr_reg_lock = self.register_manager.lockReg(addr_reg);
            defer if (addr_reg_lock) |reg| self.register_manager.unlockReg(reg);

            switch (value) {
                .register => |value_reg| {
                    try self.genStore(value_reg, addr_reg, i13, 0, abi_size);
                },
                else => {
                    return self.fail("TODO implement copying of memory", .{});
                },
            }
        },
        .memory,
        .stack_offset,
        => {
            const addr_reg = try self.copyToTmpRegister(ptr_ty, ptr);
            try self.store(.{ .register = addr_reg }, value, ptr_ty, value_ty);
        },
    }
}

fn structFieldPtr(self: *Self, inst: Air.Inst.Index, operand: Air.Inst.Ref, index: u32) !MCValue {
    return if (self.liveness.isUnused(inst)) .dead else result: {
        const mcv = try self.resolveInst(operand);
        const ptr_ty = self.air.typeOf(operand);
        const struct_ty = ptr_ty.childType();
        const struct_field_offset = @intCast(u32, struct_ty.structFieldOffset(index, self.target.*));
        switch (mcv) {
            .ptr_stack_offset => |off| {
                break :result MCValue{ .ptr_stack_offset = off - struct_field_offset };
            },
            else => {
                const offset_reg = try self.copyToTmpRegister(ptr_ty, .{
                    .immediate = struct_field_offset,
                });
                const offset_reg_lock = self.register_manager.lockRegAssumeUnused(offset_reg);
                defer self.register_manager.unlockReg(offset_reg_lock);

                const addr_reg = try self.copyToTmpRegister(ptr_ty, mcv);
                const addr_reg_lock = self.register_manager.lockRegAssumeUnused(addr_reg);
                defer self.register_manager.unlockReg(addr_reg_lock);

                const dest = try self.binOp(
                    .add,
                    .{ .register = addr_reg },
                    .{ .register = offset_reg },
                    Type.usize,
                    Type.usize,
                    null,
                );

                break :result dest;
            },
        }
    };
}

fn truncRegister(
    self: *Self,
    operand_reg: Register,
    dest_reg: Register,
    int_signedness: std.builtin.Signedness,
    int_bits: u16,
) !void {
    switch (int_bits) {
        1...31, 33...63 => {
            _ = try self.addInst(.{
                .tag = .sllx,
                .data = .{
                    .shift = .{
                        .is_imm = true,
                        .width = ShiftWidth.shift64,
                        .rd = dest_reg,
                        .rs1 = operand_reg,
                        .rs2_or_imm = .{ .imm = @intCast(u6, 64 - int_bits) },
                    },
                },
            });
            _ = try self.addInst(.{
                .tag = switch (int_signedness) {
                    .signed => .srax,
                    .unsigned => .srlx,
                },
                .data = .{
                    .shift = .{
                        .is_imm = true,
                        .width = ShiftWidth.shift32,
                        .rd = dest_reg,
                        .rs1 = dest_reg,
                        .rs2_or_imm = .{ .imm = @intCast(u6, int_bits) },
                    },
                },
            });
        },
        32 => {
            _ = try self.addInst(.{
                .tag = switch (int_signedness) {
                    .signed => .sra,
                    .unsigned => .srl,
                },
                .data = .{
                    .shift = .{
                        .is_imm = true,
                        .width = ShiftWidth.shift32,
                        .rd = dest_reg,
                        .rs1 = operand_reg,
                        .rs2_or_imm = .{ .imm = 0 },
                    },
                },
            });
        },
        64 => {
            _ = try self.addInst(.{
                .tag = .mov,
                .data = .{
                    .arithmetic_2op = .{
                        .is_imm = true,
                        .rs1 = dest_reg,
                        .rs2_or_imm = .{ .rs2 = operand_reg },
                    },
                },
            });
        },
        else => unreachable,
    }
}

/// TODO support scope overrides. Also note this logic is duplicated with `Module.wantSafety`.
fn wantSafety(self: *Self) bool {
    return switch (self.bin_file.options.optimize_mode) {
        .Debug => true,
        .ReleaseSafe => true,
        .ReleaseFast => false,
        .ReleaseSmall => false,
    };
}
