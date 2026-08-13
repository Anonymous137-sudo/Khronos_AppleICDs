// Imports one dyld-cache-backed IOGPU component in memory and writes a
// caller-owned external pseudocode report. No Apple binary is saved to AO46.

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.app.util.importer.AutoImporter;
import ghidra.app.util.importer.MessageLog;
import ghidra.app.util.opinion.LoadResults;
import ghidra.formats.gfilesystem.FileSystemRef;
import ghidra.formats.gfilesystem.FileSystemService;
import ghidra.formats.gfilesystem.GFile;
import ghidra.program.model.address.Address;
import ghidra.program.flatapi.FlatProgramAPI;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.listing.Listing;
import ghidra.program.model.listing.Program;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;
import java.io.BufferedWriter;
import java.io.File;
import java.io.FileWriter;
import java.io.IOException;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

public class AO46ImportAndExportIOGPU extends GhidraScript {
    private static final String[] OFFSET_TARGETS = {
        "0x1a56c1714:metal_resource_init",
        "0x1a56c1728:metal_resource_remote_storage_init",
        "0x1a56c8780:generic_resource_create",
        "0x1a56c1ee8:metal_resource_virtual_address",
        "0x1a56c1efc:metal_resource_gpu_address",
        "0x1a56c1f24:metal_resource_size",
        "0x1a56c2c2c:resource_pool_create_pooled_resource",
        "0x1a56acc58:buffer_backing_resource_constructor",
        "0x1a56c7db4:command_queue_create",
        "0x1a56c8090:command_queue_submit_command_buffers",
        "0x1a56ca958:resource_list_add_resource",
        "0x1a56b67e4:device_shmem_release",
        "0x1a56b6b20:device_shmem_pool_create",
        "0x1a56add88:metal_command_buffer_init",
        "0x1a56af554:metal_command_buffer_fill_arguments",
        "0x1a56ae394:metal_command_buffer_commit",
        "0x1a56b00cc:metal_command_queue_init",
        "0x1a56b09a0:metal_command_queue_submit",
        "0x1a56b0a14:metal_command_queue_submit_internal",
        "0x1a56ae140:metal_command_buffer_alloc_resource",
        "0x1a56ae314:metal_command_buffer_begin_segment",
        "0x1a56ae328:metal_command_buffer_end_segment",
        "0x1a56d0ed0:metal4_command_buffer_alloc_resource",
        "0x1a56d0ee4:metal4_command_buffer_begin_segment",
        "0x1a56d0f2c:metal4_command_buffer_end_segment",
        "0x1a56d20a4:metal4_command_buffer_commit_fill_arguments",
        "0x1a56d2570:metal4_command_queue_submit",
        "0x1a56bc13c:storage_grow_segment_list",
        "0x1a56bc320:storage_setup_shared_memory",
        "0x1a56bc45c:storage_free",
        "0x1a56bc51c:storage_deallocate",
        "0x1a56bc724:storage_release_shared_memory",
        "0x1a56bc7f8:storage_grow_kernel_commands",
        "0x1a56bcf80:storage_get_segment_list_pointers",
        "0x1a56bde88:metal4_storage_finalize_command_buffer",
        "0x1a56ca760:resource_list_init",
        "0x1a56cab00:resource_list_reset"
    };

    private static final String[] NAME_TARGETS = {
        "initWithDevice:pointer:length:",
        "initWithDevice:addressRanges:",
        "initWithDevice:options:args:argsSize:",
        "initWithDevice:remoteStorageResource:options:args:argsSize:",
        "_IOGPUResourceCreate",
        "_IOGPUMetalResourcePoolCreatePooledResource",
        "IOGPUMetalCommandBufferStoragePoolCreateStorage",
        "IOGPUMetalCommandBufferStorageCreateExt",
        "_iogpuMetalCommandBufferStorageSetupShmems",
        "_iogpuMetalCommandBufferStorageFree",
        "_IOGPUMetalCommandBufferStorageDealloc",
        "_IOGPUMetalCommandBufferStorageReleaseDeviceShmems",
        "_IOGPUMetalCommandBufferStorageGrowKernelCommandBuffer",
        "IOGPUMetalCommandBufferStorageFinalizeShmemHeader",
        "IOGPUMetalCommandBufferStorageBeginKernelCommands",
        "IOGPUMetalCommandBufferStorageBeginSegment",
        "IOGPUMetalCommandBufferStorageEndSegment",
        "IOGPUMetalCommandBufferStorageAllocResourceAtIndex",
        "IOGPUMetalCommandBufferStorageFinalizeResidencySetList",
        "IOGPUResourceListInit",
        "IOGPUResourceListReset",
        "_IOGPUMetalDeviceShmemPoolCreateShmem",
        "_IOGPUMetalDeviceShmemRelease",
        "initWithDevice:shmemSize:shmemType:",
        "setShmemSize:",
        "CommandAllocator",
        "commandAllocator",
        "initWithDeviceAndAliasToDevicePools:",
        "setHwResourcePool:count:",
        "returnCommandBufferStorage:commandAllocatorGeneration:",
        "commandBufferComplete:commandAllocator:",
        "IOGPUMetalCommandBufferStorageGetSegmentListPointers",
        "IOGPUMetalCommandBufferStorageGrowSegmentList",
        "IOGPUMetal4CommandBufferStorageFinalizeCommandBuffer",
        "_mtlIOGPUCommandBufferStorageBeginSegmentList",
        "_mtlIOGPUCommandBufferStorageEndSegmentList",
        "commitFillArgs:count:args:argsSize:commitFeedback:",
        "fillCommandBufferArgs:commandQueue:",
        "fillCommandBufferArgs_commandQueue",
        "commitAndReset",
        "_submitCommandBuffers:count:",
        "gpuAddress",
        "virtualAddress",
        "resourceSize"
    };

    private Function functionAtOffset(Program program, String offsetText) {
        long offset = Long.decode(offsetText);
        Address address = program.getImageBase().add(offset);
        return program.getFunctionManager().getFunctionAt(address);
    }

    private List<Function> functionsContaining(Program program, String fragment) {
        List<Function> matches = new ArrayList<>();
        FunctionIterator functions = program.getFunctionManager().getFunctions(true);
        while (functions.hasNext()) {
            Function function = functions.next();
            if (function.getName().contains(fragment))
                matches.add(function);
        }
        return matches;
    }

    private void writeLine(BufferedWriter writer, String text) throws IOException {
        writer.write(text);
        writer.newLine();
    }

    private String describe(Function function) {
        return function == null ? "unresolved" :
            function.getName() + " entry=" + function.getEntryPoint();
    }

    private void writeCallers(BufferedWriter writer, Program program, Function function)
            throws IOException {
        Set<String> callers = new LinkedHashSet<>();
        ReferenceIterator references = program.getReferenceManager()
            .getReferencesTo(function.getEntryPoint());

        while (references.hasNext()) {
            Reference reference = references.next();
            Function caller = program.getFunctionManager()
                .getFunctionContaining(reference.getFromAddress());
            if (caller != null && caller != function)
                callers.add(describe(caller));
        }

        writeLine(writer, "direct_callers=" + callers.size());
        for (String caller : callers)
            writeLine(writer, "  caller=" + caller);
    }

    private void writeCallees(BufferedWriter writer, Program program, Function function)
            throws IOException {
        Set<String> callees = new LinkedHashSet<>();
        Listing listing = program.getListing();
        InstructionIterator instructions = listing.getInstructions(function.getBody(), true);

        while (instructions.hasNext()) {
            Instruction instruction = instructions.next();
            for (Reference reference : instruction.getReferencesFrom()) {
                if (!reference.getReferenceType().isCall())
                    continue;

                Function callee = program.getFunctionManager()
                    .getFunctionAt(reference.getToAddress());
                if (callee != null && callee != function)
                    callees.add(describe(callee));
            }
        }

        writeLine(writer, "direct_callees=" + callees.size());
        for (String callee : callees)
            writeLine(writer, "  callee=" + callee);
    }

    private void writeFunction(BufferedWriter writer, Program program, String label,
            Function function, DecompInterface decompiler) throws IOException {
        writeLine(writer, "===== " + label + " =====");
        if (function == null) {
            writeLine(writer, "STATUS: function was not recovered");
            writeLine(writer, "");
            return;
        }

        writeLine(writer, "symbol=" + function.getName());
        writeLine(writer, "entry=" + function.getEntryPoint());
        writeCallers(writer, program, function);
        writeCallees(writer, program, function);
        DecompileResults result = decompiler.decompileFunction(function, 120, monitor);
        if (!result.decompileCompleted() || result.getDecompiledFunction() == null) {
            writeLine(writer, "STATUS: decompilation did not complete");
            writeLine(writer, "diagnostic=" + result.getErrorMessage());
            writeLine(writer, "");
            return;
        }

        writeLine(writer, result.getDecompiledFunction().getC());
        writeLine(writer, "");
    }

    private void analyzeImportedProgram(Program program) {
        FlatProgramAPI api = new FlatProgramAPI(program, monitor);
        api.start();
        try {
            api.analyzeAll(program);
        } finally {
            api.end(true);
        }
    }

    @Override
    protected void run() throws Exception {
        String[] arguments = getScriptArgs();
        if (arguments.length != 3) {
            printerr("usage: AO46ImportAndExportIOGPU.java CACHE COMPONENT_PATH OUTPUT_PATH");
            return;
        }

        FileSystemService service = FileSystemService.getInstance();
        try (FileSystemRef reference = service.probeFileForFilesystem(
                service.getLocalFSRL(new File(arguments[0])), monitor, null)) {
            if (reference == null) {
                throw new IllegalStateException("Ghidra could not open the dyld shared cache");
            }

            GFile component = reference.getFilesystem().lookup(arguments[1]);
            if (component == null || component.isDirectory()) {
                throw new IllegalArgumentException("dyld component was not found: " + arguments[1]);
            }

            MessageLog log = new MessageLog();
            try (LoadResults<Program> results = AutoImporter.importByUsingBestGuess(
                    component.getFSRL(), state.getProject(), "/AO46-Temporary", this, log, monitor)) {
                Program program = results.getPrimaryDomainObject(this);
                analyzeImportedProgram(program);
                DecompInterface decompiler = new DecompInterface();
                decompiler.toggleCCode(true);
                decompiler.toggleSyntaxTree(false);
                if (!decompiler.openProgram(program)) {
                    throw new IllegalStateException("unable to open the IOGPU program for decompilation");
                }

                try (BufferedWriter writer = new BufferedWriter(new FileWriter(arguments[2]))) {
                    writeLine(writer, "AO46 IOGPU resource and queue decompilation report");
                    writeLine(writer, "program=" + program.getName());
                    writeLine(writer, "image_base=" + program.getImageBase());
                    writeLine(writer, "");
                    for (String target : OFFSET_TARGETS) {
                        String[] fields = target.split(":", 2);
                        writeFunction(writer, program,
                            fields[1] + " offset=" + fields[0],
                            functionAtOffset(program, fields[0]), decompiler);
                    }
                    for (String fragment : NAME_TARGETS) {
                        List<Function> matches = functionsContaining(program, fragment);
                        writeLine(writer, "===== name_fragment=" + fragment + " =====");
                        writeLine(writer, "matches=" + matches.size());
                        for (Function function : matches)
                            writeFunction(writer, program, "name_match=" + fragment,
                                function, decompiler);
                    }
                } finally {
                    decompiler.dispose();
                    results.release(this);
                }
            }
        }
    }
}
