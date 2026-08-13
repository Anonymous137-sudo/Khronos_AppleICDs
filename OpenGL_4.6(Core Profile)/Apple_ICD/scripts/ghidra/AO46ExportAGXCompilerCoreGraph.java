// Read-only exporter for the AGX compiler's source-to-compiled-object graph.
// Reports are external research artifacts and intentionally omit private data
// layouts and callable request construction.

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

public class AO46ExportAGXCompilerCoreGraph extends GhidraScript {
    private static final String[] TARGETS = {
        "0x10cb4:get_compiled_object_size",
        "0x10cc0:get_compiled_object",
        "0x171b8:program_object_build_backend_request",
        "0x13e4e0:compute_programs_construct_reply",
        "0x13e8f8:compute_programs_prepare_module_and_compile",
        "0x172c30:program_object_validate_compiler_reply",
        "0x17242c:program_object_package_validated_reply",
        "0x16a684:object_array_compile",
        "0x170560:compiler_context_compile",
        "0x170fd8:compiler_context_initialize_plan",
        "0x22d6bc:agx_compile_plan_factory",
        "0x22d74c:agx_compile_plan_execute"
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

    private void allReferencesTo(BufferedWriter writer, Function function) throws IOException {
        Set<String> values = new LinkedHashSet<>();
        ReferenceIterator references = currentProgram.getReferenceManager()
            .getReferencesTo(function.getEntryPoint());
        while (references.hasNext()) {
            Reference reference = references.next();
            Function owner = currentProgram.getFunctionManager()
                .getFunctionContaining(reference.getFromAddress());
            if (owner != null) {
                values.add("code owner=" + describe(owner));
            } else {
                values.add("data from=" + reference.getFromAddress()
                    + " type=" + reference.getReferenceType());
            }
        }
        line(writer, "all_references=" + values.size());
        for (String value : values)
            line(writer, "  ref=" + value);
    }

    private void writeFunction(BufferedWriter writer, String label, Function function,
            DecompInterface decompiler) throws IOException {
        line(writer, "===== " + label + " =====");
        if (function == null) {
            line(writer, "STATUS: function was not recovered");
            line(writer, "");
            return;
        }
        line(writer, "symbol=" + describe(function));
        callers(writer, function);
        allReferencesTo(writer, function);
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
            printerr("usage: AO46ExportAGXCompilerCoreGraph.java OUTPUT_PATH");
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
            line(writer, "AO46 AGXCompilerCore source-to-compiled-object report");
            line(writer, "program=" + currentProgram.getName());
            line(writer, "image_base=" + currentProgram.getImageBase());
            line(writer, "");
            for (String target : TARGETS) {
                String[] parts = target.split(":", 2);
                writeFunction(writer, parts[1], functionAtOffset(parts[0]), decompiler);
            }
        } finally {
            decompiler.dispose();
        }
    }
}
