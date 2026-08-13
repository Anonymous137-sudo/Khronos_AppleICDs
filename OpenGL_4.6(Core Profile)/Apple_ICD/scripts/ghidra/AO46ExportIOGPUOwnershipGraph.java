// Read-only exporter for the cache-resident IOGPU ownership chain used by the
// AGX code heap. Reports remain outside the repository and are not an ABI.

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.listing.Listing;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;
import java.io.BufferedWriter;
import java.io.FileWriter;
import java.io.IOException;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

public class AO46ExportIOGPUOwnershipGraph extends GhidraScript {
    // Offsets are resolved from the active IOGPU image's runtime symbol map.
    // They are profile evidence only and are not called by AO46.
    private static final String[] TARGETS = {
        "0x153e8:pooled_resource_release",
        "0x16714:resource_initialize",
        "0x16728:resource_remote_initialize",
        "0x178a8:resource_pool_initialize",
        "0x179c4:resource_pool_set_arguments",
        "0x17a78:resource_pool_teardown",
        "0x17c2c:resource_pool_create_pooled_resource"
    };

    private static final String[] NAME_TARGETS = {
        "initWithDevice:options:args:argsSize:",
        "IOGPUMetalResourcePoolCreatePooledResource",
        "IOGPUMetalPooledResourceRelease",
        "initResourcePools:",
        "setHwResourcePool:count:",
        "virtualAddress",
        "gpuAddress",
        "resourceSize",
        "IOGPUResourceCreate",
        "IOGPUResourceGetGPUVirtualAddress"
    };

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

    private Function functionAtOffset(String offsetText) {
        long offset = Long.decode(offsetText);
        return currentProgram.getFunctionManager().getFunctionAt(
            currentProgram.getImageBase().add(offset));
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

    private void writeFunction(BufferedWriter writer, String label, Function function,
            DecompInterface decompiler) throws IOException {
        writeLine(writer, "===== " + label + " =====");
        writeLine(writer, "symbol=" + function.getName());
        writeLine(writer, "entry=" + function.getEntryPoint());
        writeCallers(writer, function);
        writeCallees(writer, function);

        DecompileResults result = decompiler.decompileFunction(function, 120, monitor);
        if (!result.decompileCompleted() || result.getDecompiledFunction() == null) {
            writeLine(writer, "STATUS: decompilation did not complete");
            writeLine(writer, "diagnostic=" + result.getErrorMessage());
        } else {
            writeLine(writer, result.getDecompiledFunction().getC());
        }
        writeLine(writer, "");
    }

    @Override
    protected void run() throws Exception {
        String[] arguments = getScriptArgs();
        if (arguments.length != 1) {
            printerr("usage: AO46ExportIOGPUOwnershipGraph.java OUTPUT_PATH");
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
            writeLine(writer, "AO46 IOGPU ownership report");
            writeLine(writer, "program=" + currentProgram.getName());
            writeLine(writer, "image_base=" + currentProgram.getImageBase());
            writeLine(writer, "");
            for (String target : TARGETS) {
                String[] fields = target.split(":", 2);
                Function function = functionAtOffset(fields[0]);
                if (function == null) {
                    writeLine(writer, "===== " + fields[1] + " offset=" + fields[0] + " =====");
                    writeLine(writer, "STATUS: function was not recovered");
                    writeLine(writer, "");
                } else {
                    writeFunction(writer, fields[1] + " offset=" + fields[0],
                        function, decompiler);
                }
            }
            for (String fragment : NAME_TARGETS) {
                List<Function> matches = functionsContaining(fragment);
                writeLine(writer, "===== name_fragment=" + fragment + " =====");
                writeLine(writer, "matches=" + matches.size());
                for (Function function : matches)
                    writeFunction(writer, "name_match=" + fragment, function, decompiler);
            }
        } finally {
            decompiler.dispose();
        }
    }
}
