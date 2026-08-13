// Read-only, profile-scoped exporter for the compiler-reply consumer chain.
// It writes decompiler output outside the repository as research evidence; it
// does not produce a private-call ABI or an executable-resource descriptor.

import ghidra.app.cmd.disassemble.DisassembleCommand;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.listing.Listing;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;
import java.io.BufferedWriter;
import java.io.FileWriter;
import java.io.IOException;
import java.util.LinkedHashSet;
import java.util.Set;

public class AO46ExportAGXConsumerBoundary extends GhidraScript {
    private static final String[] TARGETS = {
        "0x68c62c:compute_variant_constructor",
        "0x691b2c:compute_variant_finalize",
        "0x21c3ac:compiler_reply_constructor",
        "0x21bed0:compute_reply_dispatch",
        "0x21bf14:compute_reply_completion",
        "0x21c174:compute_reply_finalization",
        "0x218398:compute_variant_factory",
        "0x219a20:compute_variant_reply_consumer",
        "0x2e86d4:link_info_reply_consumer",
        "0x2e9f60:device_code_heap_allocation",
        "0x2f1244:code_heap_internal_relocations",
        "0x7ec9a4:shader_heap_allocate",
        "0x7ecb00:shader_heap_resource_factory",
        "0x7ec734:shader_heap_release",
        "0x6668c4:compute_variant_destructor"
    };

    private void writeLine(BufferedWriter writer, String value) throws IOException {
        writer.write(value);
        writer.newLine();
    }

    private Function ensureFunction(long offset) throws Exception {
        Address entry = currentProgram.getImageBase().add(offset);
        Function function = currentProgram.getFunctionManager().getFunctionAt(entry);
        if (function != null)
            return function;

        new DisassembleCommand(entry, null, true).applyTo(currentProgram, monitor);
        return createFunction(entry, null);
    }

    private void writeCallers(BufferedWriter writer, Function function) throws IOException {
        Set<String> callers = new LinkedHashSet<>();
        ReferenceIterator refs = currentProgram.getReferenceManager()
            .getReferencesTo(function.getEntryPoint());

        while (refs.hasNext()) {
            Reference ref = refs.next();
            Function caller = currentProgram.getFunctionManager()
                .getFunctionContaining(ref.getFromAddress());
            if (caller != null && caller != function)
                callers.add(caller.getName() + " entry=" + caller.getEntryPoint());
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
            for (Reference ref : instruction.getReferencesFrom()) {
                if (!ref.getReferenceType().isCall())
                    continue;
                Function callee = currentProgram.getFunctionManager()
                    .getFunctionAt(ref.getToAddress());
                if (callee != null && callee != function)
                    callees.add(callee.getName() + " entry=" + callee.getEntryPoint());
            }
        }

        writeLine(writer, "direct_callees=" + callees.size());
        for (String callee : callees)
            writeLine(writer, "  callee=" + callee);
    }

    private void writeTarget(BufferedWriter writer, String target,
            DecompInterface decompiler) throws Exception {
        String[] fields = target.split(":", 2);
        long offset = Long.decode(fields[0]);
        Function function = ensureFunction(offset);

        writeLine(writer, "===== " + fields[1] + " offset=" + fields[0] + " =====");
        if (function == null) {
            writeLine(writer, "STATUS: function recovery failed");
            writeLine(writer, "");
            return;
        }

        writeLine(writer, "entry=" + function.getEntryPoint());
        writeCallers(writer, function);
        writeCallees(writer, function);

        DecompileResults result = decompiler.decompileFunction(function, 60, monitor);
        if (!result.decompileCompleted() || result.getDecompiledFunction() == null) {
            writeLine(writer, "STATUS: decompilation failed");
            writeLine(writer, "diagnostic=" + result.getErrorMessage());
        } else {
            writeLine(writer, result.getDecompiledFunction().getC());
        }
        writeLine(writer, "");
    }

    @Override
    protected void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length != 1) {
            printerr("usage: AO46ExportAGXConsumerBoundary.java OUTPUT_PATH");
            return;
        }

        DecompInterface decompiler = new DecompInterface();
        decompiler.toggleCCode(true);
        decompiler.toggleSyntaxTree(false);
        if (!decompiler.openProgram(currentProgram)) {
            printerr("unable to open current program");
            return;
        }

        try (BufferedWriter writer = new BufferedWriter(new FileWriter(args[0]))) {
            writeLine(writer, "AO46 compiler-reply consumer boundary report");
            writeLine(writer, "program=" + currentProgram.getName());
            writeLine(writer, "image_base=" + currentProgram.getImageBase());
            writeLine(writer, "");
            for (String target : TARGETS)
                writeTarget(writer, target, decompiler);
        } finally {
            decompiler.dispose();
        }
    }
}
