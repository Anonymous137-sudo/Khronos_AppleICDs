// Profile-scoped read-only pseudocode exporter for AO46 AGX research.
// The report stays outside the repository; this script never changes the
// imported program, invokes private APIs, or produces a constructible ABI.

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import java.io.BufferedWriter;
import java.io.FileWriter;
import java.io.IOException;

public class AO46ExportAGXResidency extends GhidraScript {
    private static final String[] TARGETS = {
        "0x218398:create_compute_program_variant",
        "0x2b0c84:compute_pipeline_bind_resources",
        "0x68c62c:compute_program_variant_constructor",
        "0x7ec9a4:heap_true_allocate",
        "0x7ecb00:heap_true_allocate_queued_body",
        "0x27fde0:command_buffer_fill_arguments"
    };

    private Function functionAtOffset(String offsetText) {
        long offset = Long.decode(offsetText);
        Address address = currentProgram.getImageBase().add(offset);
        return currentProgram.getFunctionManager().getFunctionAt(address);
    }

    private void writeLine(BufferedWriter writer, String text) throws IOException {
        writer.write(text);
        writer.newLine();
    }

    @Override
    protected void run() throws Exception {
        String[] arguments = getScriptArgs();
        if (arguments.length != 1) {
            printerr("usage: AO46ExportAGXResidency.java OUTPUT_PATH");
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
            writeLine(writer, "AO46 AGX residency decompilation report");
            writeLine(writer, "program=" + currentProgram.getName());
            writeLine(writer, "image_base=" + currentProgram.getImageBase());
            writeLine(writer, "");

            for (String target : TARGETS) {
                String[] fields = target.split(":", 2);
                Function function = functionAtOffset(fields[0]);
                writeLine(writer, "===== " + fields[1] + " offset=" + fields[0] + " =====");

                if (function == null) {
                    writeLine(writer, "STATUS: function was not recovered at this exact entry");
                    writeLine(writer, "");
                    continue;
                }

                writeLine(writer, "symbol=" + function.getName());
                writeLine(writer, "entry=" + function.getEntryPoint());

                DecompileResults result = decompiler.decompileFunction(function, 120, monitor);
                if (!result.decompileCompleted() || result.getDecompiledFunction() == null) {
                    writeLine(writer, "STATUS: decompilation did not complete");
                    writeLine(writer, "diagnostic=" + result.getErrorMessage());
                    writeLine(writer, "");
                    continue;
                }

                writeLine(writer, result.getDecompiledFunction().getC());
                writeLine(writer, "");
            }
        } finally {
            decompiler.dispose();
        }
    }
}
