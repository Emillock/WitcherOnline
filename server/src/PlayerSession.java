import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.function.ToIntFunction;
import java.util.concurrent.ConcurrentHashMap;

public class PlayerSession
{
    public final int playerId;
    public final String username;
    public volatile ClientEndpoint endpoint;
    public volatile long lastSeen;

    public volatile List<String> update1AFields = Collections.emptyList();
    public volatile List<String> update1BFields = Collections.emptyList();
    public volatile List<String> update2AFields = Collections.emptyList();
    public volatile List<String> update2BFields = Collections.emptyList();
    public volatile List<String> update3Fields = Collections.emptyList();
    public volatile List<String> update4Fields = Collections.emptyList();

    // co-op state by channel (first field): latest value, forwarded on arrival and rebroadcast like the updates above
    private final Map<String, List<String>> coopFields = new ConcurrentHashMap<>();
    // when each channel was last forwarded on arrival (System.nanoTime): the broadcast tick doesn't repeat it so soon
    private final Map<String, Long> coopForwardedAt = new ConcurrentHashMap<>();

    public Iterable<String> coopChannels()
    {
        return Collections.unmodifiableSet(coopFields.keySet());
    }

    // Keep publishing and repeating a channel ordered on this session's monitor.
    public synchronized int forwardCoop(String channel, List<String> fields, int maxChannels,
            ToIntFunction<List<String>> forward)
    {
        if (channel.isEmpty() || channel.length() > 8
                || (!coopFields.containsKey(channel) && coopFields.size() >= maxChannels))
        {
            return 0;
        }

        coopFields.put(channel, fields);
        int sent = forward.applyAsInt(fields);
        coopForwardedAt.put(channel, System.nanoTime());
        return sent;
    }

    public synchronized int repeatCoop(String channel, long repeatNanos,
            ToIntFunction<List<String>> forward)
    {
        Long forwarded = coopForwardedAt.get(channel);
        if (forwarded != null && System.nanoTime() - forwarded < repeatNanos)
        {
            return 0;
        }

        // Read the value only after acquiring the lock: an iterator's entry may be stale.
        List<String> fields = coopFields.get(channel);
        return fields == null ? 0 : forward.applyAsInt(fields);
    }

    public PlayerSession(int playerId, String username, ClientEndpoint endpoint, long lastSeen)
    {
        this.playerId = playerId;
        this.username = username;
        this.endpoint = endpoint;
        this.lastSeen = lastSeen;
    }
}