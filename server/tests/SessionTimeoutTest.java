import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.net.InetAddress;
import java.util.Map;

public class SessionTimeoutTest
{
    @SuppressWarnings("unchecked")
    private static <T> Map<String, T> map(String name) throws Exception
    {
        Field field = WitcherServer.class.getDeclaredField(name);
        field.setAccessible(true);
        return (Map<String, T>) field.get(null);
    }

    private static void check(boolean condition, String message)
    {
        if (!condition)
        {
            throw new AssertionError(message);
        }
    }

    public static void main(String[] args) throws Exception
    {
        Map<String, PlayerSession> players = map("players");
        Map<String, UsernameReservation> reserved = map("reservedUsernames");
        Method expire = WitcherServer.class.getDeclaredMethod("reserveTimedOutPlayer",
                String.class, PlayerSession.class, long.class);
        expire.setAccessible(true);

        long now = 100_000_000_000L;
        ClientEndpoint endpoint = new ClientEndpoint(InetAddress.getLoopbackAddress(), 40000);
        PlayerSession player = new PlayerSession(1, "Geralt", endpoint, now - 6_000_000_000L);
        players.put("geralt", player);

        // Cleanup has observed an expired session, but a packet refreshes it before removal.
        player.lastSeen = now;
        check(!(boolean) expire.invoke(null, "geralt", player, now), "refreshed player was timed out");
        check(players.get("geralt") == player, "refreshed player disappeared");
        check(!reserved.containsKey("geralt"), "active player's username was reserved");

        // A packet can also arrive after the cleanup thread took its timestamp.
        player.lastSeen = now + 1;
        check(!(boolean) expire.invoke(null, "geralt", player, now), "newer packet was ignored");

        // An actually expired player still gets removed and reserved.
        player.lastSeen = now - 6_000_000_000L;
        check((boolean) expire.invoke(null, "geralt", player, now), "expired player was not removed");
        check(!players.containsKey("geralt"), "expired player remains connected");
        UsernameReservation reservation = reserved.get("geralt");
        check(reservation != null && reservation.username.equals("Geralt") && reservation.expiresAt > now,
                "expired player's username was not reserved");

        // A delayed cleanup must never remove a replacement session for the same username.
        reserved.clear();
        PlayerSession replacement = new PlayerSession(2, "Geralt", endpoint, now);
        players.put("geralt", replacement);
        check(!(boolean) expire.invoke(null, "geralt", player, now), "old session removed a replacement");
        check(players.get("geralt") == replacement && reserved.isEmpty(), "replacement session was modified");
        System.out.println("PASS: session timeout regression checks");
    }
}
