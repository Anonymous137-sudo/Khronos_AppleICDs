// Read-only kernel call-graph exporter. It documents ownership boundaries in
// an isolated Ghidra project and never produces a callable private ABI.

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;
import ghidra.program.model.mem.Memory;
import java.io.BufferedWriter;
import java.io.FileWriter;
import java.io.IOException;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

public class AO46ExportAGXG16XKernelGraph extends GhidraScript {
    private static final long DEVICE_METHOD_TABLE = 0xfffffe0007ea21b8L;
    private static final int DEVICE_METHOD_FIRST_SELECTOR = 0x100;
    private static final int DEVICE_METHOD_COUNT = 0x13;
    private static final int DEVICE_METHOD_STRIDE = 0x30;
    private static final String[] TARGETS = {
        "0xfffffe0008963168:accelerator_new_resource",
        "0xfffffe000896625c:accelerator_restricted_range_mapping",
        "0xfffffe00089980f4:user_client_method_table_lookup",
        "0xfffffe000898c140:queue_process_segment_kernel_command",
        "0xfffffe000898df60:queue_process_compute_setup",
        "0xfffffe000898bbe0:queue_set_protection_options",
        "0xfffffe00089979e4:user_client_invalidate_usc_instruction_cache",
        "0xfffffe0008997db4:user_client_device_va_range",
        "0xfffffe00089996c0:user_client_external_method_dispatch",
        "0xfffffe00089f3ca8:gart_code_range_info",
        "0xfffffe00089f3e20:gart_allocate_range",
        "0xfffffe00089f5004:gart_allocate_memory_map",
        "0xfffffe0008a08434:resource_initialization",
        "0xfffffe0008a07f04:resource_remove_from_aperture",
        "0xfffffe0008a07f0c:resource_add_to_aperture",
        "0xfffffe0008a07f90:resource_aperture_memory_descriptor",
        "0xfffffe0008a0805c:resource_mapping_options",
        "0xfffffe0008a095f4:resource_new_kernel_resource",
        "0xfffffe00089e94d8:internal_resource_initialization",
        "0xfffffe00089e9658:internal_resource_firmware_mapping",
        "0xfffffe00089e9810:internal_resource_prepare_mappings",
        "0xfffffe0008a1ad7c:kernel_resource_initializer",
        "0xfffffe0008a0cab4:secure_gart_restricted_range_mapping",
        "0xfffffe0008a0cbdc:secure_gart_code_range_info",
        "0xfffffe0008a0cf48:secure_gart_allocate",
        "0xfffffe0008a0d470:secure_gart_map_with_address",
        "0xfffffe0008a0acdc:secure_memory_map_commit",
        "0xfffffe0008a2ffbc:uat_map_page_table",
        "0xfffffe0008a30800:uat_create_aperture_mapping"
    };

    private static final String[] NAME_TARGETS = {
        "createRestrictedRangeMapping",
        "getCodeGartRangeInfo",
        "createMappingInAperture",
        "getTargetAndMethodForIndex",
        "newKernelResource",
        "AGXUSCPrivMemPool",
        "setProtectionOptions"
    };

    private Function functionAtAddress(String addressText) {
        String digits = addressText.startsWith("0x") ? addressText.substring(2) : addressText;
        return currentProgram.getFunctionManager().getFunctionAt(
            toAddr(Long.parseUnsignedLong(digits, 16))
        );
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

    private void line(BufferedWriter writer, String text) throws IOException {
        writer.write(text);
        writer.newLine();
    }

    private String describe(Function function) {
        return function.getName() + " entry=" + function.getEntryPoint();
    }

    private void callers(BufferedWriter writer, Function function) throws IOException {
        Set<String> values = new LinkedHashSet<>();
        ReferenceIterator references = currentProgram.getReferenceManager()
            .getReferencesTo(function.getEntryPoint());
        while (references.hasNext()) {
            Function caller = currentProgram.getFunctionManager()
                .getFunctionContaining(references.next().getFromAddress());
            if (caller != null && caller != function)
                values.add(describe(caller));
        }
        line(writer, "direct_callers=" + values.size());
        for (String value : values)
            line(writer, "  caller=" + value);
    }

    private void callees(BufferedWriter writer, Function function) throws IOException {
        Set<String> values = new LinkedHashSet<>();
        InstructionIterator instructions = currentProgram.getListing()
            .getInstructions(function.getBody(), true);
        while (instructions.hasNext()) {
            Instruction instruction = instructions.next();
            for (Reference reference : instruction.getReferencesFrom()) {
                if (!reference.getReferenceType().isCall())
                    continue;
                Function callee = currentProgram.getFunctionManager()
                    .getFunctionAt(reference.getToAddress());
                if (callee != null && callee != function)
                    values.add(describe(callee));
            }
        }
        line(writer, "direct_callees=" + values.size());
        for (String value : values)
            line(writer, "  callee=" + value);
    }

    // Direct call graphs omit virtual-method ownership. Preserve every static
    // reference in the temporary report so the code-range and restricted-map
    // policy owners can be followed without treating a vtable slot as an ABI.
    private void references(BufferedWriter writer, Function function) throws IOException {
        line(writer, "static_references=");
        ReferenceIterator iterator = currentProgram.getReferenceManager()
            .getReferencesTo(function.getEntryPoint());
        int count = 0;
        while (iterator.hasNext()) {
            Reference reference = iterator.next();
            Function owner = currentProgram.getFunctionManager()
                .getFunctionContaining(reference.getFromAddress());
            line(writer, "  reference=" + reference.getFromAddress()
                + " type=" + reference.getReferenceType()
                + " owner=" + (owner == null ? "static-data" : owner.getName()));
            count++;
        }
        line(writer, "static_reference_count=" + count);
    }

    private void writeFunction(BufferedWriter writer, String label, Function function,
            DecompInterface decompiler) throws IOException {
        line(writer, "===== " + label + " =====");
        if (function == null) {
            line(writer, "STATUS: function was not recovered");
            line(writer, "");
            return;
        }
        line(writer, "symbol=" + function.getName());
        line(writer, "entry=" + function.getEntryPoint());
        callers(writer, function);
        callees(writer, function);
        references(writer, function);

        DecompileResults result = decompiler.decompileFunction(function, 180, monitor);
        if (!result.decompileCompleted() || result.getDecompiledFunction() == null) {
            line(writer, "STATUS: decompilation did not complete");
            line(writer, "diagnostic=" + result.getErrorMessage());
            line(writer, "");
            return;
        }
        line(writer, result.getDecompiledFunction().getC());
        line(writer, "");
    }

    // This records only whether a selector has an authenticated static handler.
    // Argument layouts deliberately remain out of the report so it cannot be
    // mistaken for a callable private UABI definition.
    private void writeDeviceMethodTable(BufferedWriter writer) throws IOException {
        Memory memory = currentProgram.getMemory();
        line(writer, "===== device_user_client_method_ownership =====");
        line(writer, "selector_range=0x" + Integer.toHexString(DEVICE_METHOD_FIRST_SELECTOR)
            + "..0x" + Integer.toHexString(DEVICE_METHOD_FIRST_SELECTOR + DEVICE_METHOD_COUNT - 1));
        line(writer, "entries=" + DEVICE_METHOD_COUNT);
        for (int index = 0; index < DEVICE_METHOD_COUNT; index++) {
            int selector = DEVICE_METHOD_FIRST_SELECTOR + index;
            Address entry = toAddr(DEVICE_METHOD_TABLE + ((long) index * DEVICE_METHOD_STRIDE));
            try {
                // The first table word is the target object; the handler word
                // follows it. On arm64e it remains pointer-authenticated in the
                // static image, so resolving it as a raw address is invalid.
                long handlerValue = memory.getLong(entry.add(8));
                line(writer, "selector=0x" + Integer.toHexString(selector)
                    + " handler=" + (handlerValue == 0
                        ? "absent"
                        : "authenticated_or_indirect"));
            } catch (Exception exception) {
                line(writer, "selector=0x" + Integer.toHexString(selector)
                    + " handler=unreadable");
            }
        }
        line(writer, "");
    }

    @Override
    protected void run() throws Exception {
        String[] arguments = getScriptArgs();
        if (arguments.length != 1) {
            printerr("usage: AO46ExportAGXG16XKernelGraph.java OUTPUT_PATH");
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
            line(writer, "AO46 AGXG16X kernel ownership report");
            line(writer, "program=" + currentProgram.getName());
            line(writer, "image_base=" + currentProgram.getImageBase());
            line(writer, "");
            writeDeviceMethodTable(writer);
            for (String target : TARGETS) {
                String[] fields = target.split(":", 2);
                writeFunction(writer, fields[1] + " address=" + fields[0],
                    functionAtAddress(fields[0]), decompiler);
            }
            for (String fragment : NAME_TARGETS) {
                List<Function> matches = functionsContaining(fragment);
                line(writer, "===== name_fragment=" + fragment + " =====");
                line(writer, "matches=" + matches.size());
                for (Function function : matches)
                    writeFunction(writer, "name_match=" + fragment, function, decompiler);
            }
        } finally {
            decompiler.dispose();
        }
    }
}
