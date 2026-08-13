// Read-only, profile-scoped exporter for the IOGPU code-resource consumer
// boundary. Its temporary report is research evidence, not a private ABI.

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

public class AO46ExportIOGPUCodeAdmission extends GhidraScript {
    // Relative to the active IOGPU arm64e component image base. These are
    // profile evidence locations for static analysis only.
    private static final String[] TARGETS = {
        "0x16714:metal_resource_initializer",
        "0x16728:metal_remote_resource_initializer",
        "0x16fc0:metal_resource_virtual_address",
        "0x16fd4:metal_resource_gpu_address",
        "0x16ffc:metal_resource_size",
        "0x17c2c:resource_pool_create_pooled_resource",
        "0x1d780:generic_resource_creation"
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

    private void writeReferences(BufferedWriter writer, Function function) throws IOException {
        Set<String> callers = new LinkedHashSet<>();
        ReferenceIterator incoming = currentProgram.getReferenceManager()
            .getReferencesTo(function.getEntryPoint());
        while (incoming.hasNext()) {
            Reference reference = incoming.next();
            Function caller = currentProgram.getFunctionManager()
                .getFunctionContaining(reference.getFromAddress());
            if (caller != null && caller != function)
                callers.add(caller.getName() + " entry=" + caller.getEntryPoint());
        }
        writeLine(writer, "direct_callers=" + callers.size());
        for (String caller : callers)
            writeLine(writer, "  caller=" + caller);

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
                    callees.add(callee.getName() + " entry=" + callee.getEntryPoint());
            }
        }
        writeLine(writer, "direct_callees=" + callees.size());
        for (String callee : callees)
            writeLine(writer, "  callee=" + callee);
    }

    @Override
    protected void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length != 1) {
            printerr("usage: AO46ExportIOGPUCodeAdmission.java OUTPUT_PATH");
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
            writeLine(writer, "AO46 IOGPU code-admission boundary report");
            writeLine(writer, "program=" + currentProgram.getName());
            writeLine(writer, "image_base=" + currentProgram.getImageBase());
            writeLine(writer, "");
            for (String target : TARGETS) {
                String[] fields = target.split(":", 2);
                Function function = ensureFunction(Long.decode(fields[0]));
                writeLine(writer, "===== " + fields[1] + " offset=" + fields[0] + " =====");
                if (function == null) {
                    writeLine(writer, "STATUS: function recovery failed");
                    writeLine(writer, "");
                    continue;
                }

                writeLine(writer, "entry=" + function.getEntryPoint());
                writeReferences(writer, function);
                DecompileResults result = decompiler.decompileFunction(function, 60, monitor);
                if (!result.decompileCompleted() || result.getDecompiledFunction() == null) {
                    writeLine(writer, "STATUS: decompilation failed");
                    writeLine(writer, "diagnostic=" + result.getErrorMessage());
                } else {
                    writeLine(writer, result.getDecompiledFunction().getC());
                }
                writeLine(writer, "");
            }
        } finally {
            decompiler.dispose();
        }
    }
}
