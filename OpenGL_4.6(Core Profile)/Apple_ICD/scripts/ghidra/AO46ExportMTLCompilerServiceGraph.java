// Read-only exporter for the Apple compiler-service ownership graph. Reports
// remain outside the repository and deliberately omit XPC request layouts.

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
import java.io.BufferedWriter;
import java.io.FileWriter;
import java.io.IOException;
import java.util.LinkedHashSet;
import java.util.Set;

public class AO46ExportMTLCompilerServiceGraph extends GhidraScript {
    private static final String[] TARGETS = {
        "0x9c8:connection_context_constructor",
        "0xa7c:get_service",
        "0xab0:get_dispatch",
        "0xff4:compile_request_main",
        "0x10b4:send_reply",
        "0x1e6c:message_handler",
        "0x2354:validate_request_type",
        "0x2370:validate_connection_id",
        "0x2394:validate_llvm_version",
        "0x23d0:validate_connection_context",
        "0x23f0:validate_plugin_index",
        "0x2414:validate_request_data_pointer_and_size",
        "0x2444:validate_request_data_exists",
        "0x25a4:get_connection_context",
        "0x26b4:assign_connection_context",
        "0x2730:begin_compilation",
        "0x27b0:remove_connection_context",
        "0x2848:end_compilation"
    };

    private Function functionAtOffset(String offsetText) {
        return currentProgram.getFunctionManager().getFunctionAt(
            currentProgram.getImageBase().add(Long.decode(offsetText))
        );
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
            printerr("usage: AO46ExportMTLCompilerServiceGraph.java OUTPUT_PATH");
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
            line(writer, "AO46 MTLCompilerService ownership report");
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
