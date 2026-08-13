// Read-only dyld-cache component extractor for AO46 research.
// The extracted component is written to a caller-provided temporary path and
// must not be added to the AO46 repository.

import ghidra.app.script.GhidraScript;
import ghidra.app.util.bin.ByteProvider;
import ghidra.formats.gfilesystem.FSUtilities;
import ghidra.formats.gfilesystem.FileSystemRef;
import ghidra.formats.gfilesystem.FileSystemService;
import ghidra.formats.gfilesystem.GFile;
import java.io.File;

public class AO46ExtractDyldComponent extends GhidraScript {
    @Override
    protected void run() throws Exception {
        String[] arguments = getScriptArgs();
        if (arguments.length != 3) {
            printerr("usage: AO46ExtractDyldComponent.java CACHE COMPONENT_PATH OUTPUT_PATH");
            return;
        }

        FileSystemService service = FileSystemService.getInstance();
        File cache = new File(arguments[0]);
        File output = new File(arguments[2]);

        try (FileSystemRef reference =
                service.probeFileForFilesystem(service.getLocalFSRL(cache), monitor, null)) {
            if (reference == null) {
                throw new IllegalStateException("Ghidra could not open the dyld shared cache");
            }

            GFile component = reference.getFilesystem().lookup(arguments[1]);
            if (component == null || component.isDirectory()) {
                throw new IllegalArgumentException("dyld component was not found: " + arguments[1]);
            }

            try (ByteProvider provider = component.getFilesystem().getByteProvider(component, monitor)) {
                FSUtilities.copyByteProviderToFile(provider, output, monitor);
            }
        }

        println("AO46 extracted temporary dyld component: " + arguments[1]);
    }
}
