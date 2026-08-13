// Read-only exporter for the Apple GPUCompiler target-selection and output
// graph. Reports stay outside the repository and omit request-data layouts.

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;
import java.io.BufferedWriter;
import java.io.FileWriter;
import java.io.IOException;
import java.util.LinkedHashSet;
import java.util.Set;

public class AO46ExportGPUCompilerGraph extends GhidraScript {
    private static final String[] TARGETS = {
        "0x1c554:set_target_triple",
        "0x1c758:set_target_arch",
        "0x1e16c:lower",
        "0x1e7dc:lower_to_buffer",
        "0x39e0d8:write_metal_library_to_buffer",
        "0xb53a0:device_lowering_set_target",
        "0x3b3b88:device_lowering_lower",
        "0x284fec:fetch_plugin_for_architecture",
        "0x27334c:emit_executable_image",
        "0x278d84:opaque_plugin_supported_implementations",
        "0x277e34:matching_plugin_supported_implementations",
        "0x270edc:plugin_load",
        "0x270b10:default_plugin_wrapper",
        "0x270b18:default_wrapped_plugins"
    };

    private Function functionAtOffset(String offsetText) {
        Address address = currentProgram.getImageBase().add(Long.decode(offsetText));
        return currentProgram.getFunctionManager().getFunctionAt(address);
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

    private void writeFunction(BufferedWriter writer, Function function,
            DecompInterface decompiler) throws IOException {
        line(writer, "===== " + describe(function) + " =====");
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
            printerr("usage: AO46ExportGPUCompilerGraph.java OUTPUT_PATH");
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
            line(writer, "AO46 GPUCompiler target and output ownership report");
            line(writer, "program=" + currentProgram.getName());
            line(writer, "image_base=" + currentProgram.getImageBase());
            line(writer, "");
            for (String target : TARGETS) {
                String[] parts = target.split(":", 2);
                Function function = functionAtOffset(parts[0]);
                line(writer, "### target=" + parts[1]);
                if (function == null) {
                    line(writer, "STATUS: function was not recovered");
                    continue;
                }
                writeFunction(writer, function, decompiler);
            }
        } finally {
            decompiler.dispose();
        }
    }
}
