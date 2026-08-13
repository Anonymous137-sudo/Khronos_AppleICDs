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
import java.util.LinkedHashSet;
import java.util.Set;

public class AO46ExportAGXCompilePlanGraph extends GhidraScript {
    private static final String[] TARGETS = {
        "0x63a52c:agx_compile_plan_collect_configuration",
        "0x63a534:agx_compile_plan_execute",
        "0x187ba84:agx_compile_plan_factory",
        "0x187e860:agx_assemble_plan_execute"
    };

    private Function functionAtOffset(String offsetText) {
        Address address = currentProgram.getImageBase().add(Long.decode(offsetText));
        Function function = currentProgram.getFunctionManager().getFunctionAt(address);
        if (function != null)
            return function;

        // The fast project intentionally skips whole-image auto-analysis.
        disassemble(address);
        return createFunction(address, null);
    }

    private void line(BufferedWriter writer, String text) throws Exception {
        writer.write(text);
        writer.newLine();
    }

    private String describe(Function function) {
        return function.getName() + " entry=" + function.getEntryPoint();
    }

    private void references(BufferedWriter writer, Function function) throws Exception {
        Set<String> values = new LinkedHashSet<>();
        ReferenceIterator references = currentProgram.getReferenceManager()
            .getReferencesTo(function.getEntryPoint());
        while (references.hasNext()) {
            Reference reference = references.next();
            Function owner = currentProgram.getFunctionManager()
                .getFunctionContaining(reference.getFromAddress());
            values.add(owner == null
                ? "data from=" + reference.getFromAddress()
                : "code owner=" + describe(owner));
        }
        line(writer, "references=" + values.size());
        for (String value : values)
            line(writer, "  ref=" + value);
    }

    private void callees(BufferedWriter writer, Function function) throws Exception {
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
            DecompInterface decompiler) throws Exception {
        line(writer, "===== " + label + " =====");
        if (function == null) {
            line(writer, "STATUS: function was not recovered");
            line(writer, "");
            return;
        }
        line(writer, "symbol=" + describe(function));
        references(writer, function);
        callees(writer, function);
        DecompileResults result = decompiler.decompileFunction(function, 240, monitor);
        if (!result.decompileCompleted() || result.getDecompiledFunction() == null) {
            line(writer, "STATUS: decompilation did not complete");
            line(writer, "");
            return;
        }
        line(writer, result.getDecompiledFunction().getC());
        line(writer, "");
    }

    @Override
    protected void run() throws Exception {
        if (getScriptArgs().length != 1) {
            printerr("usage: AO46ExportAGXCompilePlanGraph.java OUTPUT_PATH");
            return;
        }
        DecompInterface decompiler = new DecompInterface();
        decompiler.openProgram(currentProgram);
        try (BufferedWriter writer = new BufferedWriter(new FileWriter(getScriptArgs()[0]))) {
            line(writer, "AO46 AGX compile-plan report");
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
