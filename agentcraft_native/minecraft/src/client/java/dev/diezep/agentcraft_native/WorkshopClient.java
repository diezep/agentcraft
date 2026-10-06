package dev.diezep.agentcraft_native;

import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.screens.ChatScreen;

/** Uses the vanilla chat screen for clickable work orders and answers. */
public final class WorkshopClient {
    private WorkshopClient() {}

    public static void openChat(int playerId) {
        var client = Minecraft.getInstance();
        client.execute(() -> {
            if (client.player != null && client.player.getId() == playerId && client.screen == null) {
                client.setScreen(new ChatScreen("", false));
            }
        });
    }
}
