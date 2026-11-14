import java.net.InetAddress;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.FutureTask;
import java.util.concurrent.TimeUnit;

public class CoopOrderingTest
{
    private static void check(boolean condition, String message)
    {
        if (!condition)
        {
            throw new AssertionError(message);
        }
    }

    private static void await(CountDownLatch latch)
    {
        try
        {
            check(latch.await(5, TimeUnit.SECONDS), "timed out waiting for test thread");
        }
        catch (InterruptedException e)
        {
            Thread.currentThread().interrupt();
            throw new AssertionError(e);
        }
    }

    public static void main(String[] args) throws Exception
    {
        PlayerSession player = new PlayerSession(1, "Geralt",
                new ClientEndpoint(InetAddress.getLoopbackAddress(), 40000), 0);
        List<String> old = List.of("en", "old");
        List<String> fresh = List.of("en", "new");
        List<List<String>> sent = new ArrayList<>();
        check(player.forwardCoop("en", old, 16, fields -> 1) == 1, "initial update failed");

        CountDownLatch repeating = new CountDownLatch(1);
        CountDownLatch release = new CountDownLatch(1);
        FutureTask<Integer> repeat = new FutureTask<>(() -> player.repeatCoop("en", 0, fields -> {
            repeating.countDown();
            await(release);
            sent.add(fields);
            return 1;
        }));
        Thread repeatThread = new Thread(repeat);
        repeatThread.setDaemon(true);
        repeatThread.start();
        try
        {
            await(repeating);
            FutureTask<Integer> publish = new FutureTask<>(() -> player.forwardCoop("en", fresh, 16, fields -> {
                sent.add(fields);
                return 1;
            }));
            Thread publishThread = new Thread(publish);
            publishThread.setDaemon(true);
            publishThread.start();
            long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
            while (publishThread.getState() != Thread.State.BLOCKED && !publish.isDone()
                    && System.nanoTime() < deadline)
            {
                Thread.sleep(1);
            }
            check(publishThread.getState() == Thread.State.BLOCKED,
                    "new state can overtake a repeat already in progress");
            release.countDown();
            check(repeat.get(5, TimeUnit.SECONDS) == 1, "repeat failed");
            check(publish.get(5, TimeUnit.SECONDS) == 1, "publish failed");
            check(sent.equals(List.of(old, fresh)), "updates were forwarded out of order: " + sent);
        }
        finally
        {
            release.countDown();
        }

        check(player.repeatCoop("en", Long.MAX_VALUE, fields -> {
            throw new AssertionError("recent update was repeated");
        }) == 0, "recent update should be skipped");
        check(player.repeatCoop("en", 0, fields -> {
            check(fields.equals(fresh), "repeat used obsolete state");
            return 1;
        }) == 1, "latest update was not repeated");
        check(player.repeatCoop("missing", 0, fields -> 1) == 0, "unknown channel was repeated");
        for (int i = 1; i < 16; i++)
        {
            String channel = "c" + i;
            check(player.forwardCoop(channel, List.of(channel), 16, fields -> 1) == 1, "channel rejected");
        }
        check(player.forwardCoop("c16", List.of("c16"), 16, fields -> 1) == 0, "capacity not enforced");
        check(player.forwardCoop("en", fresh, 16, fields -> 1) == 1, "update at capacity rejected");
        check(player.forwardCoop("toolongname", List.of("toolongname"), 16, fields -> 1) == 0, "overlong name accepted");
        System.out.println("PASS: co-op forwarding order, repeat and capacity");
    }
}