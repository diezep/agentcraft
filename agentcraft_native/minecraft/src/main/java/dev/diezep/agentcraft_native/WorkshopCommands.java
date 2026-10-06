package dev.diezep.agentcraft_native;

import com.redstone.DartBridge;

/** World presentation updates run on the server thread without chat spam. */
public final class WorkshopCommands {
    private WorkshopCommands() {}

    public static void execute(String command) {
        var server = DartBridge.getServerInstance();
        if (server == null) return;
        server.execute(() -> server.getCommands().performPrefixedCommand(
            server.createCommandSourceStack().withSuppressedOutput(), command));
    }
}
