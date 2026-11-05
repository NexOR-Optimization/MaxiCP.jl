package maxicpjl;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;

/**
 * A routing model given by MathOptVRP sets, recorded by MaxiCP.jl and solved by
 * {@link VrpWorker}s, each building its own copy of the CP model.
 *
 * Nodes {@code 0..n-1} are the MathOptVRP nodes {@code 1..n}; each of the
 * {@code numRoutes} routes, the columns of a {@code Partition}, gets its own copies
 * of a start and an end node. The other variables of the MOI model are integer
 * variables, by index.
 */
public class VrpSpec {

    // senses of linear constraints
    public static final int LE = -1, EQ = 0, GE = 1;

    final int n, numRoutes;
    final List<int[]> varBounds = new ArrayList<>();
    final List<Definition> definitions = new ArrayList<>();
    final List<Schedule> schedules = new ArrayList<>();
    final List<Linear> linears = new ArrayList<>();
    final List<RouteConstraint> routeConstraints = new ArrayList<>();
    Linear objective;
    boolean minimize = true;

    public VrpSpec(int n, int numRoutes) {
        this.n = n;
        this.numRoutes = numRoutes;
    }

    // ------------------------------------------------------------ recording

    public int addVar(int lb, int ub) {
        varBounds.add(new int[]{lb, ub});
        return varBounds.size() - 1;
    }

    public void setBounds(int var, int lb, int ub) {
        int[] b = varBounds.get(var);
        b[0] = Math.max(b[0], lb);
        b[1] = Math.min(b[1], ub);
    }

    enum DefinitionKind { IS_EMPTY, SUM_GET_INDEX, SUM_DISTANCES }

    record Definition(DefinitionKind kind, int var, int route, int[] values,
                      int[][] matrix, int first, int last) {}

    public void defineIsEmpty(int var, int route) {
        definitions.add(new Definition(DefinitionKind.IS_EMPTY, var, route, null, null, 0, 0));
    }

    public void defineSumGetIndex(int var, int route, int[] values) {
        definitions.add(new Definition(DefinitionKind.SUM_GET_INDEX, var, route, values,
                null, 0, 0));
    }

    public void defineSumDistances(int var, int route, int[] distance, int first, int last) {
        definitions.add(new Definition(DefinitionKind.SUM_DISTANCES, var, route, null,
                square(distance), first, last));
    }

    /** The data of one MathOptVRP.VehicleSchedule; node rows are 0-based. */
    record Schedule(int[] routes, int[] tripStart, int[] tripEnd, int taken,
                    int breakStart, int[] visit, int[][] travel, int depot,
                    int[] earliest, int[] latest, int[] service, int dayEarliest,
                    int dayLatest, int firstService, int reloadFixed, int[] reload,
                    int breakLength, int breakFrom, int breakTo) {}

    public void addSchedule(int[] routes, int[] tripStart, int[] tripEnd, int taken,
                            int breakStart, int[] visit, int[] travel, int depot,
                            int[] earliest, int[] latest, int[] service, int dayEarliest,
                            int dayLatest, int firstService, int reloadFixed,
                            int[] reload, int breakLength, int breakFrom, int breakTo) {
        schedules.add(new Schedule(routes, tripStart, tripEnd, taken, breakStart, visit,
                square(travel), depot, earliest, latest, service, dayEarliest, dayLatest,
                firstService, reloadFixed, reload, breakLength, breakFrom, breakTo));
    }

    enum RouteKind { COMPATIBILITY, ORDER, EXTREMITIES, CAPACITY }

    record RouteConstraint(RouteKind kind, int route, int[] a, int[] b, int bound) {}

    public void addCompatibility(int route, int[] allowed) {
        routeConstraints.add(new RouteConstraint(RouteKind.COMPATIBILITY, route, allowed, null, 0));
    }

    public void addRouteOrder(int route, int[] before, int[] after) {
        routeConstraints.add(new RouteConstraint(RouteKind.ORDER, route, before, after, 0));
    }

    public void addRouteExtremities(int route, int[] members) {
        routeConstraints.add(new RouteConstraint(RouteKind.EXTREMITIES, route, members, null, 0));
    }

    public void addCapacity(int route, int[] delta, int capacity) {
        for (int d : delta)
            if (d < 0)
                throw new IllegalArgumentException(
                        "MaxiCP: Capacity with negative deltas is not supported");
        routeConstraints.add(new RouteConstraint(RouteKind.CAPACITY, route, delta, null, capacity));
    }

    /**
     * {@code sum(coefs[i] * vars[i]) sense rhs}, enforced only when
     * {@code activation} (-1 for none) has the value {@code activeValue}.
     */
    record Linear(int[] vars, int[] coefs, int sense, int rhs, int activation,
                  int activeValue) {}

    public void addLinear(int[] vars, int[] coefs, int sense, int rhs) {
        linears.add(new Linear(vars, coefs, sense, rhs, -1, 0));
    }

    public void addIndicator(int activation, int activeValue, int[] vars, int[] coefs,
                             int sense, int rhs) {
        linears.add(new Linear(vars, coefs, sense, rhs, activation, activeValue));
    }

    public void setObjective(int[] vars, int[] coefs, int constant, boolean minimize) {
        this.objective = new Linear(vars, coefs, EQ, -constant, -1, 0);
        this.minimize = minimize;
    }

    private int[][] square(int[] flat) {
        int size = (int) Math.round(Math.sqrt(flat.length));
        if (size * size != flat.length)
            throw new IllegalArgumentException("expected a square matrix");
        int[][] m = new int[size][size];
        for (int i = 0; i < size; i++)
            System.arraycopy(flat, i * size, m[i], 0, size);
        return m;
    }

    // ------------------------------------------------------------ solving

    /** An immutable solution, shared between workers. */
    record Snapshot(long score, int dropped, int objective, int[][] routes, int[] values,
                    int[] times) {}

    Snapshot best;
    String status = "OPTIMIZE_NOT_CALLED";

    /**
     * Solves with {@code workers} parallel workers for {@code timeLimit} seconds.
     * Returns the status: {@code SOLVED} when a solution visits every node,
     * {@code INFEASIBLE} when the model has none, or {@code NO_SOLUTION}.
     */
    public String solve(double timeLimit, long seed, int workers, boolean verbose) {
        long deadline = System.currentTimeMillis() + Math.round(timeLimit * 1000);
        AtomicReference<Snapshot> global = new AtomicReference<>();
        AtomicLong infeasible = new AtomicLong();
        List<Thread> threads = new ArrayList<>();
        int count = Math.max(1, workers);
        for (int w = 0; w < count; w++) {
            final int id = w;
            Thread thread = new Thread(() -> {
                try {
                    new VrpWorker(this, "w" + id, seed + 101L * id, deadline, global,
                            verbose).run();
                } catch (VrpWorker.RootInfeasible e) {
                    infeasible.incrementAndGet();
                }
            }, "maxicp-vrp-" + id);
            threads.add(thread);
        }
        if (count == 1) {
            threads.get(0).run();
        } else {
            for (Thread t : threads) t.start();
            for (Thread t : threads) {
                try {
                    t.join();
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
            }
        }
        best = global.get();
        if (best == null)
            status = infeasible.get() == count ? "INFEASIBLE" : "NO_SOLUTION";
        else
            status = best.dropped() == 0 ? "SOLVED" : "NO_SOLUTION";
        return status;
    }

    public String status() {
        return status;
    }

    public int objectiveValue() {
        return best.objective();
    }

    public int[] values() {
        return best.values();
    }

    /** The 0-based nodes visited by {@code route}, in order. */
    public int[] routeNodes(int route) {
        return best.routes()[route];
    }
}
