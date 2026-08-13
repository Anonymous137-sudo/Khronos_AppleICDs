// Profile-scoped read-only call-graph and pseudocode exporter for the private
// AGX ownership chains. Reports are written outside the repository and are
// research evidence, never a callable private ABI.

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.cmd.disassemble.DisassembleCommand;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.listing.Listing;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;
import java.io.BufferedWriter;
import java.io.FileWriter;
import java.io.IOException;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

public class AO46ExportAGXBlockerGraph extends GhidraScript {
    private static final String[] TARGETS = {
        "0x68c62c:shader_variant_constructor",
        "0x691b2c:shader_variant_finalize",
        "0x7ec9a4:shader_heap_allocate",
        "0x7ecb00:shader_heap_resource_factory",
        "0x7ec810:shader_heap_resource_signpost",
        "0x7ec734:shader_heap_release_queued_body",
        "0x2e9f60:device_code_heap_allocation",
        "0x2ea304:device_code_heap_release",
        "0x2ea6fc:code_link_info_initialize",
        "0x2f1244:code_heap_internal_relocations",
        "0x6668c4:compute_variant_base_destructor",
        "0x6669ac:compute_program_variant_owner_teardown",
        "0x2c4b74:device_resource_pool_setup",
        "0x2861a8:command_allocator_resource_pool_initialization",
        "0x2c2ae4:deferred_device_code_heap_setup",
        "0x2c6f54:driver_shader_compilation_setup",
        "0x2ce6d0:device_accelerator_initialization",
        "0x2e703c:usc_heap_config_template_initialization",
        "0x2e71a0:device_usc_setup_primary",
        "0x2e734c:device_usc_setup_secondary",
        "0x32dad4:usc_profile_control_kernel_initialization",
        "0x32dcfc:usc_profile_control_global_configuration",
        "0x324c2c:usc_profile_state_loader_instruction_emission",
        "0x2b4574:usc_variant_consumer",
        "0x27fde0:agx_command_argument_lowering",
        "0x219a20:user_compute_variant_factory_block",
        "0x2a3200:indirect_compute_patch_variant_block",
        "0x2a3fa0:indirect_compute_range_variant_block",
        "0x2c83e0:threadgroup_optimization_variant_block",
        "0x2e2294:uber_blit_variant_block",
        "0x2e2b20:fast_clear_variant_block",
        "0x2e2d68:control_flow_predicate_variant_block",
        "0x2e6168:progress_marker_variant_block",
        "0x21c3ac:compiler_reply_constructor",
        "0x21d308:compiler_reply_deserialization",
        "0x21bed0:compute_compiler_reply_dispatch",
        "0x21bf14:compute_compiler_reply_completion",
        "0x21bfc4:compute_compiler_reply_binary_completion",
        "0x21c014:compute_compiler_reply_cache_completion",
        "0x21c174:compute_compiler_reply_finalization",
        "0x218398:compute_variant_factory",
        "0x219a20:compute_variant_reply_consumer",
        "0x2e86d4:link_info_compiler_reply_consumer"
    };

    private static final String[] NAME_TARGETS = {
        "allocateCodeHeap",
        "deallocateCodeHeap",
        "Heap<true>::allocateImpl",
        "initWithDevice:descriptor:",
        "setupHWResourcePools",
        "initResourcePools:",
        "heapConfigs",
        "setupDeferred",
        "compileDriverShaders",
        "appendStateLoaderInstructions",
        "initializeWithKernelState",
        "emitGlobalConfigurationInit",
        "initializeCodeHeap",
        "HeapSet",
        "deallocateImpl",
        "applyInternalRelocations",
        "ComputeProgramVariant",
        "freeCodeHeap",
        "releaseCodeHeap"
    };

    private static final long RESOURCE_POOL_DISPATCH_TABLE = 0x2c4dacL;
    private static final long RESOURCE_POOL_DISPATCH_ANCHOR = 0x2c4d34L;
    private static final long RESOURCE_POOL_DISPATCH_REGION_START = 0x2c4c24L;
    private static final long RESOURCE_POOL_DISPATCH_REGION_END = 0x2c4da8L;
    private static final int RESOURCE_POOL_CLASS_COUNT = 44;

    private Function functionAtOffset(String offsetText) {
        long offset = Long.decode(offsetText);
        Address address = currentProgram.getImageBase().add(offset);
        return currentProgram.getFunctionManager().getFunctionAt(address);
    }

    private List<Function> functionsContaining(String fragment) {
        List<Function> matches = new ArrayList<>();
        FunctionIterator functions = currentProgram.getFunctionManager().getFunctions(true);
        while (functions.hasNext()) {
            Function function = functions.next();
            if (function.getName().contains(fragment))
                matches.add(function);
        }
        return matches;
    }

    private void writeLine(BufferedWriter writer, String text) throws IOException {
        writer.write(text);
        writer.newLine();
    }

    private String describe(Function function) {
        return function == null ? "unresolved" :
            function.getName() + " entry=" + function.getEntryPoint();
    }

    private void writeCallers(BufferedWriter writer, Function function) throws IOException {
        Set<String> callers = new LinkedHashSet<>();
        ReferenceIterator references = currentProgram.getReferenceManager()
            .getReferencesTo(function.getEntryPoint());

        while (references.hasNext()) {
            Reference reference = references.next();
            Function caller = currentProgram.getFunctionManager()
                .getFunctionContaining(reference.getFromAddress());
            if (caller != null && caller != function)
                callers.add(describe(caller));
        }

        writeLine(writer, "direct_callers=" + callers.size());
        for (String caller : callers)
            writeLine(writer, "  caller=" + caller);
    }

    private void writeCallees(BufferedWriter writer, Function function) throws IOException {
        Set<String> callees = new LinkedHashSet<>();
        Listing listing = currentProgram.getListing();
        InstructionIterator instructions = listing.getInstructions(function.getBody(), true);

        while (instructions.hasNext()) {
            Instruction instruction = instructions.next();
            for (Reference reference : instruction.getReferencesFrom()) {
                if (!reference.getReferenceType().isCall())
                    continue;

                Function callee = currentProgram.getFunctionManager()
                    .getFunctionAt(reference.getToAddress());
                if (callee != null && callee != function)
                    callees.add(describe(callee));
            }
        }

        writeLine(writer, "direct_callees=" + callees.size());
        for (String callee : callees)
            writeLine(writer, "  callee=" + callee);
    }

    // Preserve unresolved dispatch evidence in the temporary report so an
    // indirect constructor can be traced without inventing a callable ABI.
    private void writeIndirectTransfers(BufferedWriter writer, Function function) throws IOException {
        Listing listing = currentProgram.getListing();
        InstructionIterator instructions = listing.getInstructions(function.getBody(), true);
        int count = 0;

        while (instructions.hasNext()) {
            Instruction instruction = instructions.next();
            if (!instruction.getFlowType().isCall() && !instruction.getFlowType().isJump())
                continue;

            boolean direct = !instruction.getFlowType().isComputed();
            for (Reference reference : instruction.getReferencesFrom()) {
                if (!reference.getReferenceType().isCall() &&
                        !reference.getReferenceType().isJump())
                    continue;
                if (currentProgram.getFunctionManager().getFunctionAt(reference.getToAddress()) != null) {
                    direct = true;
                    break;
                }
            }
            if (direct)
                continue;

            count++;
            writeLine(writer, "  indirect_transfer=" + instruction.getAddress() + " " + instruction +
                " flow=" + instruction.getFlowType());
            for (Reference reference : instruction.getReferencesFrom())
                writeLine(writer, "    reference=" + reference.getFromAddress() + " -> " +
                    reference.getToAddress() + " type=" + reference.getReferenceType());
        }

        writeLine(writer, "unresolved_indirect_transfers=" + count);
    }

    private void writeTailWindow(BufferedWriter writer, Function function) throws IOException {
        Listing listing = currentProgram.getListing();
        List<Instruction> tail = new ArrayList<>();
        InstructionIterator instructions = listing.getInstructions(function.getBody(), true);
        while (instructions.hasNext()) {
            tail.add(instructions.next());
            if (tail.size() > 12)
                tail.remove(0);
        }

        writeLine(writer, "tail_instruction_window=" + tail.size());
        for (Instruction entry : tail) {
            writeLine(writer, "  instruction=" + entry.getAddress() + " " + entry);
            for (Reference reference : entry.getReferencesFrom())
                writeLine(writer, "    reference=" + reference.getFromAddress() + " -> " +
                    reference.getToAddress() + " type=" + reference.getReferenceType());
        }
    }

    private void writeComputedTransferWindows(BufferedWriter writer, Function function)
            throws IOException {
        Listing listing = currentProgram.getListing();
        InstructionIterator instructions = listing.getInstructions(function.getBody(), true);

        while (instructions.hasNext()) {
            Instruction transfer = instructions.next();
            if (!transfer.getFlowType().isComputed())
                continue;

            List<Instruction> window = new ArrayList<>();
            Instruction cursor = transfer;
            while (cursor != null && function.getBody().contains(cursor.getAddress()) &&
                    window.size() < 10) {
                window.add(0, cursor);
                cursor = cursor.getPrevious();
            }

            writeLine(writer, "computed_transfer_window=" + transfer.getAddress());
            for (Instruction entry : window) {
                writeLine(writer, "  instruction=" + entry.getAddress() + " " + entry);
                for (Reference reference : entry.getReferencesFrom())
                    writeLine(writer, "    reference=" + reference.getFromAddress() + " -> " +
                        reference.getToAddress() + " type=" + reference.getReferenceType());
            }
        }
    }

    // The device setup routine selects one of 44 slot-class blocks with a
    // signed-offset jump table. Export the finite table to temporary evidence
    // rather than treating it as a single opaque factory call.
    private void writeResourcePoolDispatchTable(BufferedWriter writer) throws Exception {
        Memory memory = currentProgram.getMemory();
        Listing listing = currentProgram.getListing();
        Address table = currentProgram.getImageBase().add(RESOURCE_POOL_DISPATCH_TABLE);
        Address anchor = currentProgram.getImageBase().add(RESOURCE_POOL_DISPATCH_ANCHOR);

        writeLine(writer, "===== resource_pool_dispatch_table =====");
        writeLine(writer, "slot_classes=" + RESOURCE_POOL_CLASS_COUNT);
        for (int slot = 0; slot < RESOURCE_POOL_CLASS_COUNT; slot++) {
            Address entry = table.add(slot * 4L);
            int relative = memory.getInt(entry);
            Address target = anchor.add(relative);
            writeLine(writer, "slot=" + slot + " entry=" + entry + " target=" + target);

            Instruction instruction = listing.getInstructionAt(target);
            int emitted = 0;
            while (instruction != null && emitted < 18) {
                writeLine(writer, "  instruction=" + instruction.getAddress() + " " + instruction);
                for (Reference reference : instruction.getReferencesFrom())
                    writeLine(writer, "    reference=" + reference.getFromAddress() + " -> " +
                        reference.getToAddress() + " type=" + reference.getReferenceType());
                emitted++;
                if (instruction.getFlowType().isTerminal() || instruction.getFlowType().isJump())
                    break;
                instruction = instruction.getNext();
            }
        }
    }

    private void recoverResourcePoolDispatchBlocks() throws Exception {
        Memory memory = currentProgram.getMemory();
        Address table = currentProgram.getImageBase().add(RESOURCE_POOL_DISPATCH_TABLE);
        Address anchor = currentProgram.getImageBase().add(RESOURCE_POOL_DISPATCH_ANCHOR);
        Set<Address> targets = new LinkedHashSet<>();

        for (int slot = 0; slot < RESOURCE_POOL_CLASS_COUNT; slot++) {
            int relative = memory.getInt(table.add(slot * 4L));
            targets.add(anchor.add(relative));
        }
        for (Address target : targets) {
            // These basic blocks are reached only through a computed branch.
            // Recover them in the temporary Ghidra project for reporting.
            new DisassembleCommand(target, null, true).applyTo(currentProgram, monitor);
        }
    }

    private void writeResourcePoolDispatchRegion(BufferedWriter writer) throws IOException {
        Listing listing = currentProgram.getListing();
        Address start = currentProgram.getImageBase().add(RESOURCE_POOL_DISPATCH_REGION_START);
        Address end = currentProgram.getImageBase().add(RESOURCE_POOL_DISPATCH_REGION_END);
        Instruction instruction = listing.getInstructionAt(start);

        writeLine(writer, "===== resource_pool_dispatch_region =====");
        while (instruction != null && instruction.getAddress().compareTo(end) <= 0) {
            writeLine(writer, "instruction=" + instruction.getAddress() + " " + instruction);
            for (Reference reference : instruction.getReferencesFrom())
                writeLine(writer, "  reference=" + reference.getFromAddress() + " -> " +
                    reference.getToAddress() + " type=" + reference.getReferenceType());
            instruction = instruction.getNext();
        }
    }

    private void writeFunction(BufferedWriter writer, String label, Function function,
            DecompInterface decompiler) throws IOException {
        writeLine(writer, "===== " + label + " =====");
        if (function == null) {
            writeLine(writer, "STATUS: function was not recovered");
            writeLine(writer, "");
            return;
        }

        writeLine(writer, "symbol=" + function.getName());
        writeLine(writer, "entry=" + function.getEntryPoint());
        writeCallers(writer, function);
        writeCallees(writer, function);
        writeIndirectTransfers(writer, function);
        writeTailWindow(writer, function);
        writeComputedTransferWindows(writer, function);

        DecompileResults result = decompiler.decompileFunction(function, 120, monitor);
        if (!result.decompileCompleted() || result.getDecompiledFunction() == null) {
            writeLine(writer, "STATUS: decompilation did not complete");
            writeLine(writer, "diagnostic=" + result.getErrorMessage());
            writeLine(writer, "");
            return;
        }

        writeLine(writer, result.getDecompiledFunction().getC());
        writeLine(writer, "");
    }

    @Override
    protected void run() throws Exception {
        String[] arguments = getScriptArgs();
        if (arguments.length != 1) {
            printerr("usage: AO46ExportAGXBlockerGraph.java OUTPUT_PATH");
            return;
        }

        DecompInterface decompiler = new DecompInterface();
        decompiler.toggleCCode(true);
        decompiler.toggleSyntaxTree(false);
        if (!decompiler.openProgram(currentProgram)) {
            printerr("unable to open the current program for decompilation");
            return;
        }

        try (BufferedWriter writer = new BufferedWriter(new FileWriter(arguments[0]))) {
            recoverResourcePoolDispatchBlocks();
            writeLine(writer, "AO46 AGX blocker call-graph report");
            writeLine(writer, "program=" + currentProgram.getName());
            writeLine(writer, "image_base=" + currentProgram.getImageBase());
            writeLine(writer, "");
            for (String target : TARGETS) {
                String[] fields = target.split(":", 2);
                writeFunction(writer, fields[1] + " offset=" + fields[0],
                    functionAtOffset(fields[0]), decompiler);
            }
            for (String fragment : NAME_TARGETS) {
                List<Function> matches = functionsContaining(fragment);
                writeLine(writer, "===== name_fragment=" + fragment + " =====");
                writeLine(writer, "matches=" + matches.size());
                for (Function function : matches)
                    writeFunction(writer, "name_match=" + fragment, function, decompiler);
            }
            writeResourcePoolDispatchTable(writer);
            writeResourcePoolDispatchRegion(writer);
        } finally {
            decompiler.dispose();
        }
    }
}
