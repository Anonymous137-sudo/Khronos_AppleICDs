// Read-only IOGPUFamily ownership exporter. Its output is research evidence,
// not a private ABI definition or a source of callable request layouts.

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.symbol.Reference;
import java.io.BufferedWriter;
import java.io.FileWriter;
import java.io.IOException;
import java.util.LinkedHashSet;
import java.util.Set;

public class AO46ExportIOGPUKernelGraph extends GhidraScript {
    private static final String[] TARGETS = {
        "0xfffffe000a7bc4e4:user_client_new_resource",
        "0xfffffe000a7bee1c:user_client_resource_admission",
        "0xfffffe000a7be8c4:device_user_client_start",
        "0xfffffe000a7becec:device_user_client_external_method",
        "0xfffffe000a7bc14c:user_client_new_command_queue",
        "0xfffffe000a7bc898:user_client_submit_command_buffers",
        "0xfffffe000a7ddaa4:device_new_resource",
        "0xfffffe000a7dc8ac:device_is_restricted_client",
        "0xfffffe000a7de4c0:device_create_user_gpu_task",
        "0xfffffe000a7cc3ec:resource_initialize",
        "0xfffffe000a7ca8d4:resource_new_with_options",
        "0xfffffe000a7cb7ac:resource_new_with_client_address_ranges",
        "0xfffffe000a7ccdf8:resource_map_at_address_length",
        "0xfffffe000a7cb214:resource_get_protection_options",
        "0xfffffe000a7f5530:memory_map_allocate_gpu_va",
        "0xfffffe000a7f5a9c:memory_map_set_allocation_parameters",
        "0xfffffe000a7f5c78:memory_map_commit_gpu_page_table"
    };

    private void line(BufferedWriter writer, String text) throws IOException {
        writer.write(text);
        writer.newLine();
    }

    private Function functionAtAddress(String addressText) {
        return currentProgram.getFunctionManager().getFunctionAt(
            toAddr(Long.parseUnsignedLong(addressText.substring(2), 16))
        );
    }

    private String describe(Function function) {
        return function.getName() + " entry=" + function.getEntryPoint();
    }

    private void callers(BufferedWriter writer, Function function) throws IOException {
        Set<String> values = new LinkedHashSet<>();
        for (Reference reference : currentProgram.getReferenceManager()
                .getReferencesTo(function.getEntryPoint())) {
            Function caller = currentProgram.getFunctionManager()
                .getFunctionContaining(reference.getFromAddress());
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

    @Override
    protected void run() throws Exception {
        String[] arguments = getScriptArgs();
        if (arguments.length != 1) {
            printerr("usage: AO46ExportIOGPUKernelGraph.java OUTPUT_PATH");
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
            line(writer, "AO46 IOGPUFamily kernel ownership report");
            line(writer, "program=" + currentProgram.getName());
            line(writer, "image_base=" + currentProgram.getImageBase());
            line(writer, "");
            for (String target : TARGETS) {
                String[] fields = target.split(":", 2);
                writeFunction(writer, fields[1] + " address=" + fields[0],
                    functionAtAddress(fields[0]), decompiler);
            }
        } finally {
            decompiler.dispose();
        }
    }
}
