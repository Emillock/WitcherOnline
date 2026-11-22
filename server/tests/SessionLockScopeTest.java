import java.io.IOException;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.net.SocketException;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.FutureTask;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

public class SessionLockScopeTest
{
    private static class BlockingSocket extends DatagramSocket
    {
        final CountDownLatch firstSend = new CountDownLatch(1);
        final CountDownLatch release = new CountDownLatch(1);
        final AtomicBoolean first = new AtomicBoolean(true);
        volatile boolean heldRegistryLock;

        BlockingSocket() throws SocketException
        {
            super(0);
        }

        @Override
        public void send(DatagramPacket packet) throws IOException
        {
            if (first.compareAndSet(true, false))
            {
                heldRegistryLock = Thread.holdsLock(WitcherServer.class);
                firstSend.countDown();
                try
                {
                    if (!release.await(5, TimeUnit.SECONDS))
                    {
                        throw new IOException("first broadcast was not released");
                    }
                }
                catch (InterruptedException e)
                {
                    Thread.currentThread().interrupt();
                    throw new IOException(e);
                }
            }
            // No network I/O needed for this test: observing the send is enough.
        }
    }

    private static void check(boolean condition, String message)
    {
        if (!condition)
        {
            throw new AssertionError(message);
        }
    }

    @SuppressWarnings("unchecked")
    private static Map<String, PlayerSession> players() throws Exception
    {
        Field field = WitcherServer.class.getDeclaredField("players");
        field.setAccessible(true);
        return (Map<String, PlayerSession>) field.get(null);
    }

    private static void move(Method handler, DatagramSocket socket, String name, int port)
            throws Exception
    {
        handler.invoke(null, socket, new ClientEndpoint(InetAddress.getLoopbackAddress(), port),
                "MOVE\t" + name + "\t1\t0\t0\t0\t1\t0\t0\t0");
    }

    public static void main(String[] args) throws Exception
    {
        Method handler = WitcherServer.class.getDeclaredMethod("handleMessage",
                DatagramSocket.class, ClientEndpoint.class, String.class);
        handler.setAccessible(true);
        Method kick = WitcherServer.class.getDeclaredMethod("kickPlayer",
                DatagramSocket.class, PlayerSession.class, String.class);
        kick.setAccessible(true);

        Map<String, PlayerSession> players = players();
        players.clear();
        try (BlockingSocket socket = new BlockingSocket())
        {
            FutureTask<Void> alice = new FutureTask<>(() -> {
                move(handler, socket, "Alice", 32001);
                return null;
            });
            Thread thread = new Thread(alice, "slow-alice-broadcast");
            thread.setDaemon(true);
            thread.start();
            try
            {
                check(socket.firstSend.await(5, TimeUnit.SECONDS),
                        "the first outgoing packet was not observed");
                check(!socket.heldRegistryLock,
                        "the registry lock is held while forwarding a UDP datagram");

                FutureTask<Void> bob = new FutureTask<>(() -> {
                    move(handler, socket, "Bob", 32002);
                    return null;
                });
                Thread bobThread = new Thread(bob, "bob-broadcast");
                bobThread.setDaemon(true);
                bobThread.start();
                bob.get(3, TimeUnit.SECONDS); // Bob must not wait for Alice's slow send.
                check(players.containsKey("bob"), "another player could not update");

                PlayerSession victim = players.get("alice");
                check(victim != null, "Alice is missing");
                FutureTask<Void> removal = new FutureTask<>(() -> {
                    kick.invoke(null, socket, victim, "KICK\tTest");
                    return null;
                });
                Thread remover = new Thread(removal, "kick-while-broadcasting");
                remover.setDaemon(true);
                remover.start();
                long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3);
                while (remover.getState() != Thread.State.BLOCKED && !removal.isDone()
                        && System.nanoTime() < deadline)
                {
                    Thread.sleep(1);
                }
                check(remover.getState() == Thread.State.BLOCKED,
                        "kick did not wait for the active player's send");
                socket.release.countDown();
                alice.get(5, TimeUnit.SECONDS);
                removal.get(5, TimeUnit.SECONDS);
                check(!players.containsKey("alice") && players.containsKey("bob"),
                        "kicking one player changed another session");
            }
            finally
            {
                socket.release.countDown();
                alice.get(5, TimeUnit.SECONDS);
            }
        }
        System.out.println("PASS: slow send does not hold registry lock; kick waits per player");
    }
}
