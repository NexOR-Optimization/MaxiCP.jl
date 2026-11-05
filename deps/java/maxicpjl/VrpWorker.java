package maxicpjl;

import org.maxicp.cp.engine.constraints.seqvar.Distance;
import org.maxicp.cp.engine.constraints.seqvar.Exclude;
import org.maxicp.cp.engine.constraints.seqvar.Insert;
import org.maxicp.cp.engine.constraints.seqvar.Precedence;
import org.maxicp.cp.engine.constraints.seqvar.TransitionTimes;
import org.maxicp.cp.engine.core.CPBoolVar;
import org.maxicp.cp.engine.core.CPIntVar;
import org.maxicp.cp.engine.core.CPSeqVar;
import org.maxicp.cp.engine.core.CPSolver;
import org.maxicp.modeling.algebra.sequence.SeqStatus;
import org.maxicp.search.DFSearch;
import org.maxicp.search.IntObjective;
import org.maxicp.search.Searches;
import org.maxicp.util.exception.InconsistencyException;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Random;
import java.util.Set;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.Supplier;

import static org.maxicp.cp.CPFactory.*;

/**
 * One worker solving a {@link VrpSpec}: its own CP model with one sequence
 * variable per route, a construction by regret insertion and an adaptive large
 * neighborhood search. Nodes may be dropped at a penalty while searching; only
 * the solutions visiting every node are solutions of the MOI model.
 *
 * The breaks are decided first,
 * so that {@link BreakNoOverlap} prunes the insertions, then the nodes are
 * inserted by regret, and the times are fixed last.
 */
class VrpWorker {

    static class RootInfeasible extends RuntimeException {}

    static final int RESTART_FAIL_LIMIT = 8_000;
    static final int LNS_FAIL_LIMIT_MIN = 150;
    static final int LNS_FAIL_LIMIT_MAX = 1200;
    static final int LNS_MAX_DISCREPANCY = 4;
    static final int TIME_BOUND = 100_000_000;

    final VrpSpec spec;
    final String label;
    final long deadline;
    final AtomicReference<VrpSpec.Snapshot> global;
    final boolean verbose;
    final Random rnd;
    final int n, nRoutes, nNodes;

    CPSolver cp;
    CPSeqVar[] seq;
    CPIntVar[] time;
    CPIntVar[] vars;
    CPBoolVar[] used;
    CPBoolVar[] served;
    CPIntVar objective, signedObjective, drops;
    int[][][] heuristic;          // [route] node x node detour costs
    int[] group;                  // route -> vehicle: the routes of a schedule
    int[][] groupRoutes;
    boolean[] scheduled;          // route has times
    // per schedule: the break decisions
    CPIntVar[] breakTaken, breakStart;
    int[] breakGuide;
    int[] takenGuide;             // per schedule: 1 to try a break first, else 0
    Map<Integer, Integer> guide;  // node -> preferred group

    VrpWorker(VrpSpec spec, String label, long seed, long deadline,
              AtomicReference<VrpSpec.Snapshot> global, boolean verbose) {
        this.spec = spec;
        this.label = label;
        this.deadline = deadline;
        this.global = global;
        this.verbose = verbose;
        this.rnd = new Random(seed);
        this.n = spec.n;
        this.nRoutes = spec.numRoutes;
        this.nNodes = n + 2 * nRoutes;
    }

    int startNode(int r) { return n + 2 * r; }

    int endNode(int r) { return n + 2 * r + 1; }

    // ================================================================ model

    void build() {
        cp = makeSolver();
        seq = new CPSeqVar[nRoutes];
        for (int r = 0; r < nRoutes; r++) {
            seq[r] = makeSeqVar(cp, nNodes, startNode(r), endNode(r));
            for (int node = n; node < nNodes; node++)
                if (node != startNode(r) && node != endNode(r))
                    cp.post(new Exclude(seq[r], node));
        }
        used = new CPBoolVar[nRoutes];
        for (int r = 0; r < nRoutes; r++) {
            CPIntVar[] req = new CPIntVar[n];
            for (int o = 0; o < n; o++) req[o] = seq[r].isNodeRequired(o);
            used[r] = n == 0 ? makeBoolVar(cp, false, true) : isGe(sum(req), 1);
        }
        served = new CPBoolVar[n];
        for (int o = 0; o < n; o++) {
            CPIntVar[] req = new CPIntVar[nRoutes];
            for (int r = 0; r < nRoutes; r++) req[r] = seq[r].isNodeRequired(o);
            CPIntVar count = sum(req);
            cp.post(le(count, 1));
            served[o] = isGe(count, 1);
        }

        vars = new CPIntVar[spec.varBounds.size()];
        group = new int[nRoutes];
        Arrays.fill(group, -1);
        scheduled = new boolean[nRoutes];
        heuristic = new int[nRoutes][][];
        buildTimes();
        for (VrpSpec.Definition d : spec.definitions) define(d);
        for (int i = 0; i < vars.length; i++) {
            int[] b = spec.varBounds.get(i);
            if (vars[i] == null) {
                vars[i] = makeIntVar(cp, b[0], b[1]);
            } else {
                if (b[0] > vars[i].min()) cp.post(ge(vars[i], b[0]));
                if (b[1] < vars[i].max()) cp.post(le(vars[i], b[1]));
            }
        }
        List<int[]> groups = new ArrayList<>();
        for (int s = 0; s < spec.schedules.size(); s++) groups.add(spec.schedules.get(s).routes());
        for (int r = 0; r < nRoutes; r++)
            if (group[r] < 0) {
                group[r] = groups.size();
                groups.add(new int[]{r});
            }
        groupRoutes = groups.toArray(new int[0][]);
        for (int r = 0; r < nRoutes; r++)
            if (heuristic[r] == null) heuristic[r] = new int[nNodes][nNodes];
        postSchedules();
        for (VrpSpec.RouteConstraint c : spec.routeConstraints) post(c);
        for (VrpSpec.Linear l : spec.linears) post(l);

        objective = spec.objective == null ? makeIntVar(cp, 0, 0) : linear(spec.objective);
        // solutions are compared on their drops first, then on the objective
        drops = n == 0 ? makeIntVar(cp, 0, 0) : plus(minus(sum(served)), n);
        signedObjective = spec.minimize ? objective : minus(objective);
    }

    /** Times of the scheduled nodes; created before the definitions read them. */
    void buildTimes() {
        time = new CPIntVar[nNodes];
        int lo = Integer.MAX_VALUE, hi = Integer.MIN_VALUE;
        for (VrpSpec.Schedule s : spec.schedules)
            for (int o = 0; o < n; o++) {
                lo = Math.min(lo, s.earliest()[o]);
                hi = Math.max(hi, s.latest()[o]);
            }
        for (int o = 0; o < n; o++)
            time[o] = spec.schedules.isEmpty() ? makeIntVar(cp, 0, 0) : makeIntVar(cp, lo, hi);
        for (int r = 0; r < nRoutes; r++) {
            time[startNode(r)] = makeIntVar(cp, 0, 0);
            time[endNode(r)] = makeIntVar(cp, 0, 0);
        }
        breakTaken = new CPIntVar[spec.schedules.size()];
        breakStart = new CPIntVar[spec.schedules.size()];
        for (int si = 0; si < spec.schedules.size(); si++) {
            VrpSpec.Schedule s = spec.schedules.get(si);
            for (int t = 0; t < s.routes().length; t++) {
                int r = s.routes()[t];
                if (group[r] >= 0)
                    throw new IllegalArgumentException("MaxiCP: a route in two VehicleSchedules");
                group[r] = si;
                scheduled[r] = true;
                time[startNode(r)] = makeIntVar(cp, s.dayEarliest(), s.dayLatest());
                time[endNode(r)] = makeIntVar(cp, s.dayEarliest(), s.dayLatest());
                vars[s.tripStart()[t]] = time[startNode(r)];
                vars[s.tripEnd()[t]] = time[endNode(r)];
                heuristic[r] = travelMatrix(s, t, r);
            }
        }
    }

    /** The travel times of trip {@code t} of {@code s} between the nodes of route r. */
    int[][] travelMatrix(VrpSpec.Schedule s, int t, int r) {
        int[][] m = new int[nNodes][nNodes];
        int[] row = new int[nNodes];
        for (int o = 0; o < n; o++) row[o] = o;
        for (int node = n; node < nNodes; node++) row[node] = s.depot();
        // the depot copies of the other routes are excluded, but keep the
        // triangle inequality that TransitionTimes checks
        for (int i = 0; i < nNodes; i++)
            for (int j = 0; j < nNodes; j++)
                m[i][j] = s.travel()[row[i]][row[j]];
        // the depot service before the first trip, counted only when it
        // visits a node
        if (t == 0)
            for (int o = 0; o < n; o++) m[startNode(r)][o] += s.firstService();
        return m;
    }

    void postSchedules() {
        int nSchedules = spec.schedules.size();
        breakGuide = new int[nSchedules];
        Arrays.fill(breakGuide, Integer.MIN_VALUE);
        takenGuide = new int[nSchedules];
        Arrays.fill(takenGuide, 1);
        for (int si = 0; si < nSchedules; si++) {
            VrpSpec.Schedule s = spec.schedules.get(si);
            int[] routes = s.routes();
            int[] service = new int[nNodes];
            System.arraycopy(s.service(), 0, service, 0, n);
            for (int t = 0; t < routes.length; t++) {
                int r = routes[t];
                cp.post(new TransitionTimes(seq[r], time, heuristic[r], service));
                if (t > 0) {
                    List<CPIntVar> terms = new ArrayList<>();
                    terms.add(time[endNode(routes[t - 1])]);
                    if (s.reloadFixed() != 0) terms.add(mul(used[r], s.reloadFixed()));
                    for (int o = 0; o < n; o++)
                        if (s.reload()[o] != 0)
                            terms.add(mul(seq[r].isNodeRequired(o), s.reload()[o]));
                    cp.post(ge(time[startNode(r)], sum(terms.toArray(new CPIntVar[0]))));
                }
            }
            // the windows of this vehicle when they are tighter than the domains
            CPBoolVar[] on = new CPBoolVar[n];
            for (int o = 0; o < n; o++) {
                CPBoolVar[] req = new CPBoolVar[routes.length];
                for (int t = 0; t < routes.length; t++) req[t] = seq[routes[t]].isNodeRequired(o);
                on[o] = routes.length == 1 ? req[0] : isOr(req);
                if (s.earliest()[o] > time[o].min())
                    cp.post(le(on[o], isGe(time[o], s.earliest()[o])));
                if (s.latest()[o] < time[o].max())
                    cp.post(le(on[o], isLe(time[o], s.latest()[o])));
                setVar(s.visit()[o], mul(time[o], on[o]));
            }
            CPIntVar taken = vars[s.taken()], start = vars[s.breakStart()];
            CPBoolVar isTaken = isEq(taken, 1);
            breakTaken[si] = taken;
            breakStart[si] = start;
            int first = startNode(routes[0]), last = endNode(routes[routes.length - 1]);
            cp.post(le(isTaken, isGe(start, s.breakFrom())));
            cp.post(le(isTaken, isLe(start, s.breakTo())));
            cp.post(le(isTaken, isGe(start, time[first])));
            cp.post(le(isTaken, isLe(plus(start, s.breakLength()), time[last])));
            if (s.breakLength() > 0) {
                CPSeqVar[] trips = new CPSeqVar[routes.length];
                int[][][] travel = new int[routes.length][][];
                for (int t = 0; t < routes.length; t++) {
                    trips[t] = seq[routes[t]];
                    travel[t] = heuristic[routes[t]];
                }
                cp.post(new BreakNoOverlap(trips, n, time, service, isTaken, start,
                        s.breakLength(), travel, s.reloadFixed(), s.reload()));
            }
        }
    }

    void setVar(int index, CPIntVar value) {
        if (vars[index] == null) vars[index] = value;
        else cp.post(eq(vars[index], value));
    }

    void define(VrpSpec.Definition d) {
        int r = d.route();
        switch (d.kind()) {
            case IS_EMPTY -> setVar(d.var(), not(used[r]));
            case SUM_GET_INDEX -> {
                List<CPIntVar> terms = new ArrayList<>();
                for (int o = 0; o < n; o++)
                    if (d.values()[o] != 0)
                        terms.add(d.values()[o] == 1 ? seq[r].isNodeRequired(o)
                                : mul(seq[r].isNodeRequired(o), d.values()[o]));
                setVar(d.var(), terms.isEmpty() ? makeIntVar(cp, 0, 0)
                        : terms.size() == 1 ? terms.get(0) : sum(terms.toArray(new CPIntVar[0])));
            }
            case SUM_DISTANCES -> {
                int[][] m = new int[nNodes][nNodes];
                int[] row = new int[nNodes];
                int total = 0;
                for (int o = 0; o < n; o++) row[o] = o;
                for (int q = 0; q < nRoutes; q++) {
                    row[startNode(q)] = d.first();
                    row[endNode(q)] = d.last();
                }
                for (int i = 0; i < nNodes; i++)
                    for (int j = 0; j < nNodes; j++) {
                        m[i][j] = d.matrix()[row[i]][row[j]];
                        total = Math.max(total, m[i][j]);
                    }
                CPIntVar length = makeIntVar(cp, 0, total * (n + 1));
                cp.post(new Distance(seq[r], m, length));
                int empty = d.matrix()[d.first()][d.last()];
                setVar(d.var(), empty == 0 ? length : sum(length, mul(not(used[r]), -empty)));
                if (!scheduled[r]) heuristic[r] = m;
            }
        }
    }

    void post(VrpSpec.RouteConstraint c) {
        CPSeqVar s = seq[c.route()];
        switch (c.kind()) {
            case COMPATIBILITY -> {
                for (int o = 0; o < n; o++)
                    if (c.a()[o] == 0) cp.post(new Exclude(s, o));
            }
            case ORDER -> {
                for (int p = 0; p < n; p++)
                    if (c.a()[p] != 0)
                        for (int q = 0; q < n; q++)
                            if (c.b()[q] != 0) cp.post(new Precedence(s, p, q));
            }
            case EXTREMITIES -> {
                if (!scheduled[c.route()])
                    throw new IllegalArgumentException(
                            "MaxiCP: RouteExtremities needs the route in a VehicleSchedule");
                List<Integer> members = new ArrayList<>(), others = new ArrayList<>();
                for (int o = 0; o < n; o++)
                    if (!s.isNode(o, SeqStatus.EXCLUDED))
                        (c.a()[o] != 0 ? members : others).add(o);
                cp.post(new FirstOrLast(s, toArray(members), toArray(others), time));
            }
            case CAPACITY -> {
                List<CPIntVar> terms = new ArrayList<>();
                for (int o = 0; o < n; o++)
                    if (c.a()[o] != 0) terms.add(mul(s.isNodeRequired(o), c.a()[o]));
                if (!terms.isEmpty())
                    cp.post(le(sum(terms.toArray(new CPIntVar[0])), c.bound()));
            }
        }
    }

    CPIntVar linear(VrpSpec.Linear l) {
        List<CPIntVar> terms = new ArrayList<>();
        for (int i = 0; i < l.vars().length; i++) {
            int c = l.coefs()[i];
            if (c == 0) continue;
            terms.add(c == 1 ? vars[l.vars()[i]] : mul(vars[l.vars()[i]], c));
        }
        CPIntVar e = terms.isEmpty() ? makeIntVar(cp, 0, 0)
                : terms.size() == 1 ? terms.get(0) : sum(terms.toArray(new CPIntVar[0]));
        // an objective is recorded as `expression == -constant`
        return l.rhs() == 0 ? e : plus(e, -l.rhs());
    }

    void post(VrpSpec.Linear l) {
        CPIntVar e = linear(new VrpSpec.Linear(l.vars(), l.coefs(), VrpSpec.EQ, 0, -1, 0));
        int rhs = l.rhs();
        if (l.activation() < 0) {
            switch (l.sense()) {
                case VrpSpec.LE -> cp.post(le(e, rhs));
                case VrpSpec.GE -> cp.post(ge(e, rhs));
                default -> cp.post(eq(e, rhs));
            }
            return;
        }
        CPBoolVar active = isEq(vars[l.activation()], l.activeValue());
        CPBoolVar holds = switch (l.sense()) {
            case VrpSpec.LE -> isLe(e, rhs);
            case VrpSpec.GE -> isGe(e, rhs);
            default -> isEq(e, rhs);
        };
        cp.post(le(active, holds));
    }

    static int[] toArray(List<Integer> list) {
        return list.stream().mapToInt(Integer::intValue).toArray();
    }

    // ================================================================ search

    boolean isMemberSomewhere(int o) {
        for (CPSeqVar s : seq) if (s.isNode(o, SeqStatus.MEMBER)) return true;
        return false;
    }

    boolean everywhereExcluded(int o) {
        for (CPSeqVar s : seq) if (!s.isNode(o, SeqStatus.EXCLUDED)) return false;
        return true;
    }

    Runnable dropBranch(int o) {
        return () -> {
            for (CPSeqVar s : seq)
                if (!s.isNode(o, SeqStatus.EXCLUDED)) cp.post(new Exclude(s, o));
        };
    }

    Runnable[] fixToward(CPIntVar x, boolean towardMax) {
        int mid = (int) (((long) x.min() + x.max()) >> 1);
        Runnable lo = () -> cp.post(le(x, mid));
        Runnable hi = () -> cp.post(ge(x, mid + 1));
        return towardMax ? new Runnable[]{hi, lo} : new Runnable[]{lo, hi};
    }

    /** The breaks first: taken, then their start, toward the incumbent's. */
    Supplier<Runnable[]> breakFixing() {
        return () -> {
            for (int si = 0; si < breakTaken.length; si++) {
                CPIntVar taken = breakTaken[si];
                if (!taken.isFixed()) {
                    int g = takenGuide[si];
                    return new Runnable[]{() -> cp.post(eq(taken, g)),
                            () -> cp.post(eq(taken, 1 - g))};
                }
                if (taken.min() == 0 || spec.schedules.get(si).breakLength() == 0) continue;
                CPIntVar b = breakStart[si];
                if (!b.isFixed()) {
                    int g = breakGuide[si];
                    if (b.contains(g))
                        return new Runnable[]{() -> cp.post(eq(b, g)), () -> cp.post(neq(b, g))};
                    return fixToward(b, false);
                }
            }
            return Searches.EMPTY;
        };
    }

    /** Regret-2 insertion of the unplaced nodes, dropping a node last. */
    Supplier<Runnable[]> regretBranching(double noise) {
        int[] buf = new int[nNodes];
        record Ins(int route, int pred, double detour) {}
        return () -> {
            int bestNode = -1;
            double bestRegret = Double.NEGATIVE_INFINITY, bestCheapest = 0;
            for (int o = 0; o < n; o++) {
                if (isMemberSomewhere(o) || everywhereExcluded(o)) continue;
                double b1 = Double.POSITIVE_INFINITY, b2 = Double.POSITIVE_INFINITY;
                boolean insertable = false;
                for (int r = 0; r < nRoutes; r++) {
                    CPSeqVar s = seq[r];
                    if (!s.isNode(o, SeqStatus.INSERTABLE)) continue;
                    insertable = true;
                    int[][] h = heuristic[r];
                    int m = s.fillInsert(o, buf);
                    for (int i = 0; i < m; i++) {
                        int pred = buf[i], succ = s.memberAfter(pred);
                        double det = h[pred][o] + h[o][succ] - h[pred][succ];
                        if (noise > 0) det *= 1 + noise * rnd.nextDouble();
                        if (det < b1) { b2 = b1; b1 = det; } else if (det < b2) b2 = det;
                    }
                }
                if (!insertable) return new Runnable[]{dropBranch(o)};
                double regret = b2 == Double.POSITIVE_INFINITY ? Double.MAX_VALUE : b2 - b1;
                if (regret > bestRegret || (regret == bestRegret && b1 > bestCheapest)) {
                    bestRegret = regret;
                    bestCheapest = b1;
                    bestNode = o;
                }
            }
            if (bestNode == -1) return Searches.EMPTY;
            final int node = bestNode;
            List<Ins> inss = new ArrayList<>();
            for (int r = 0; r < nRoutes; r++) {
                CPSeqVar s = seq[r];
                if (!s.isNode(node, SeqStatus.INSERTABLE)) continue;
                int[][] h = heuristic[r];
                int m = s.fillInsert(node, buf);
                for (int i = 0; i < m; i++) {
                    int pred = buf[i], succ = s.memberAfter(pred);
                    inss.add(new Ins(r, pred, h[pred][node] + h[node][succ] - h[pred][succ]));
                }
            }
            final Integer pref = guide == null ? null : guide.get(node);
            inss.sort(Comparator
                    .comparingInt((Ins in) -> pref != null && pref == group[in.route()] ? 0 : 1)
                    .thenComparingDouble(Ins::detour));
            List<Runnable> branches = new ArrayList<>();
            for (Ins in : inss)
                branches.add(() -> cp.post(new Insert(seq[in.route()], in.pred(), node)));
            branches.add(dropBranch(node));
            return branches.toArray(new Runnable[0]);
        };
    }

    /** The departures as late as possible, then the visits as early as possible. */
    Supplier<Runnable[]> scheduleFixing() {
        return () -> {
            for (int o = 0; o < n; o++)
                if (!isMemberSomewhere(o) && !everywhereExcluded(o))
                    return new Runnable[]{() -> { throw InconsistencyException.INCONSISTENCY; }};
            for (VrpSpec.Schedule s : spec.schedules) {
                CPIntVar departure = time[startNode(s.routes()[0])];
                if (!departure.isFixed()) return fixToward(departure, true);
            }
            for (int r = 0; r < nRoutes; r++) {
                if (!scheduled[r]) continue;
                CPSeqVar s = seq[r];
                for (int node = s.start(); ; node = s.memberAfter(node)) {
                    if (!time[node].isFixed()) return fixToward(time[node], false);
                    if (node == s.end()) break;
                }
            }
            for (CPIntVar x : vars)
                if (!x.isFixed()) return fixToward(x, false);
            return Searches.EMPTY;
        };
    }

    Supplier<Runnable[]> branching(double noise, int discrepancy) {
        Supplier<Runnable[]> regret = regretBranching(noise);
        if (discrepancy > 0) regret = Searches.limitedDiscrepancy(regret, discrepancy);
        return Searches.and(breakFixing(), regret, scheduleFixing());
    }

    // ================================================================ run

    VrpSpec.Snapshot best;
    int[][] bestMembers;          // [route] ordered members with start and end

    /** Lexicographic: the drops, then the signed objective. */
    static long score(int dropped, int signedObjective) {
        return ((long) dropped << 32) + signedObjective;
    }

    void capture() {
        long s = score(drops.min(), signedObjective.min());
        if (best != null && s >= best.score()) return;
        int[][] routes = new int[nRoutes][];
        bestMembers = new int[nRoutes][];
        for (int r = 0; r < nRoutes; r++) {
            int[] members = new int[seq[r].nNode(SeqStatus.MEMBER)];
            seq[r].fillNode(members, SeqStatus.MEMBER_ORDERED);
            bestMembers[r] = members;
            routes[r] = Arrays.copyOfRange(members, 1, members.length - 1);
        }
        int[] values = new int[vars.length];
        for (int i = 0; i < vars.length; i++) values[i] = vars[i].min();
        int[] times = new int[nNodes];
        for (int i = 0; i < nNodes; i++) times[i] = time[i].min();
        int dropped = 0;
        for (int o = 0; o < n; o++) if (served[o].min() == 0) dropped++;
        best = new VrpSpec.Snapshot(s, dropped, objective.min(), routes, values, times);
        for (int si = 0; si < breakStart.length; si++) {
            breakGuide[si] = breakStart[si].min();
            takenGuide[si] = breakTaken[si].min();
        }
        VrpSpec.Snapshot mine = best;
        global.accumulateAndGet(mine, (cur, x) -> cur == null || x.score() < cur.score() ? x : cur);
        if (verbose)
            System.out.printf("  [%s] solution: objective %d, %d dropped%n", label,
                    mine.objective(), dropped);
    }

    void adopt(VrpSpec.Snapshot g) {
        best = g;
        bestMembers = new int[nRoutes][];
        for (int r = 0; r < nRoutes; r++) {
            int[] nodes = g.routes()[r];
            int[] members = new int[nodes.length + 2];
            members[0] = startNode(r);
            System.arraycopy(nodes, 0, members, 1, nodes.length);
            members[members.length - 1] = endNode(r);
            bestMembers[r] = members;
        }
        for (int si = 0; si < breakStart.length; si++) {
            VrpSpec.Schedule s = spec.schedules.get(si);
            breakGuide[si] = g.values()[s.breakStart()];
            takenGuide[si] = g.values()[s.taken()];
        }
    }

    void run() {
        try {
            build();
            cp.fixPoint();
        } catch (InconsistencyException e) {
            throw new RootInfeasible();
        }
        IntObjective obj = cp.minimize(signedObjective);
        long budget = deadline - System.currentTimeMillis();
        long constructionEnd = System.currentTimeMillis() + budget * 6 / 10;
        for (int restart = 0; best == null && System.currentTimeMillis() < constructionEnd;
             restart++) {
            DFSearch dfs = makeDfs(cp, branching(restart == 0 ? 0 : 0.1, 0));
            dfs.onSolution(this::capture);
            final int limit = RESTART_FAIL_LIMIT * (1 + restart);
            dfs.optimize(obj, st -> st.numberOfSolutions() >= 1
                    || st.numberOfFailures() > limit
                    || System.currentTimeMillis() > constructionEnd);
        }
        if (best == null) return;
        lns();
    }

    void lns() {
        Supplier<Set<Integer>>[] hoods = neighborhoods();
        double[] weight = new double[hoods.length];
        Arrays.fill(weight, 1.0);
        int sinceImproved = 0, failLimit = LNS_FAIL_LIMIT_MIN, iter = 0;
        while (System.currentTimeMillis() < deadline) {
            iter++;
            if (sinceImproved >= 30) {
                VrpSpec.Snapshot g = global.get();
                if (g != null && g.score() < best.score()) {
                    adopt(g);
                    sinceImproved = 0;
                }
            }
            int nb = roulette(weight);
            Set<Integer> relaxed = hoods[nb].get();
            if (relaxed.isEmpty()) continue;
            for (int kick = (sinceImproved - 50) / 20; kick > 0 && relaxed.size() < n; kick--)
                relaxed.add(rnd.nextInt(n));
            long before = best.score();
            boolean bigMove = nb >= hoods.length - 2;
            final int fl = bigMove ? LNS_FAIL_LIMIT_MAX : failLimit;
            Map<Integer, Integer> pg = new HashMap<>();
            for (int o = 0; o < n; o++)
                if (best.times() != null && !isServed(o)) pg.put(o, rnd.nextInt(groupRoutes.length));
            guide = pg;
            // now and then, try the other side of a vehicle's break decision
            int flipped = -1;
            if (takenGuide.length > 0 && rnd.nextDouble() < 0.1) {
                flipped = rnd.nextInt(takenGuide.length);
                takenGuide[flipped] = 1 - takenGuide[flipped];
                for (int route : spec.schedules.get(flipped).routes())
                    for (int node : best.routes()[route]) relaxed.add(node);
            }
            int maxDisc = Math.max(LNS_MAX_DISCREPANCY, relaxed.size() / 2);
            DFSearch probe = makeDfs(cp, branching(0.05, maxDisc));
            probe.onSolution(this::capture);
            long probeDeadline = Math.min(deadline,
                    System.currentTimeMillis() + (bigMove ? 5000 : 2000));
            final int[][] members = bestMembers;
            // while nodes are dropped, half of the probes serve one more at
            // any cost; the others keep the drops and improve the objective
            final boolean coverage = best.dropped() > 0 && (bigMove || rnd.nextBoolean());
            final int maxDrops = coverage ? best.dropped() - 1 : best.dropped();
            IntObjective obj = cp.minimize(signedObjective);
            if (!coverage) obj.setBound((int) (best.score() - ((long) best.dropped() << 32)) - 1);
            try {
                probe.optimizeSubjectTo(obj,
                        st -> st.numberOfFailures() > fl || st.numberOfSolutions() >= 3
                                || System.currentTimeMillis() > probeDeadline,
                        () -> {
                            cp.post(le(drops, maxDrops));
                            for (int r = 0; r < nRoutes; r++)
                                cp.post(new PartialRelaxedSequence(seq[r], members[r], relaxed));
                        });
            } catch (InconsistencyException ignored) {
            }
            guide = null;
            if (flipped >= 0 && best.score() >= before)
                takenGuide[flipped] = 1 - takenGuide[flipped];
            weight[nb] = Math.max(0.5, weight[nb] * 0.995);
            if (best.score() < before) {
                weight[nb] += 1.0;
                sinceImproved = 0;
                failLimit = LNS_FAIL_LIMIT_MIN;
            } else if (++sinceImproved % 40 == 0 && failLimit < LNS_FAIL_LIMIT_MAX) {
                failLimit *= 2;
            }
        }
        if (verbose)
            System.out.printf("  [%s] LNS: %d iterations, objective %d, %d dropped%n",
                    label, iter, best.objective(), best.dropped());
    }

    boolean isServed(int o) {
        for (int[] route : best.routes()) for (int x : route) if (x == o) return true;
        return false;
    }

    int roulette(double[] w) {
        double total = 0;
        for (double x : w) total += x;
        double pick = rnd.nextDouble() * total;
        for (int i = 0; i < w.length; i++) {
            pick -= w[i];
            if (pick <= 0) return i;
        }
        return w.length - 1;
    }

    /** The vehicle (schedule) and neighbors of node o in the incumbent, or null. */
    int[] position(int o) {
        for (int r = 0; r < nRoutes; r++) {
            int[] m = bestMembers[r];
            for (int i = 1; i < m.length - 1; i++)
                if (m[i] == o) return new int[]{r, m[i - 1], m[i + 1]};
        }
        return null;
    }

    @SuppressWarnings("unchecked")
    Supplier<Set<Integer>>[] neighborhoods() {
        // relatedness: the heuristic matrix of a route that may visit both
        int[][] h = heuristic[0];
        Supplier<Set<Integer>> random = () -> {
            Set<Integer> r = new HashSet<>();
            int size = Math.min(n, 5 + rnd.nextInt(8));
            while (r.size() < size) r.add(rnd.nextInt(n));
            return r;
        };
        Supplier<Set<Integer>> shaw = () -> {
            Set<Integer> r = new HashSet<>();
            if (n == 0) return r;
            r.add(rnd.nextInt(n));
            int size = Math.min(n, 6 + rnd.nextInt(7));
            while (r.size() < size) {
                int seed = r.stream().skip(rnd.nextInt(r.size())).findFirst().orElseThrow();
                int bestO = -1;
                double bestRel = Double.POSITIVE_INFINITY;
                for (int o = 0; o < n; o++) {
                    if (r.contains(o)) continue;
                    double rel = h[seed][o] + 0.3 * Math.abs(best.times()[seed] - best.times()[o]);
                    rel *= 1 + 0.4 * rnd.nextDouble();
                    if (rel < bestRel) { bestRel = rel; bestO = o; }
                }
                r.add(bestO);
            }
            return r;
        };
        Supplier<Set<Integer>> worst = () -> {
            List<int[]> detours = new ArrayList<>();
            for (int o = 0; o < n; o++) {
                int[] pos = position(o);
                if (pos == null) continue;
                int[][] m = heuristic[pos[0]];
                detours.add(new int[]{o, m[pos[1]][o] + m[o][pos[2]] - m[pos[1]][pos[2]]});
            }
            detours.sort((x, y) -> y[1] - x[1]);
            Set<Integer> r = new HashSet<>();
            int size = 5 + rnd.nextInt(6);
            while (r.size() < size && !detours.isEmpty()) {
                int idx = (int) (detours.size() * Math.pow(rnd.nextDouble(), 3));
                r.add(detours.remove(idx)[0]);
            }
            return r;
        };
        Supplier<Set<Integer>> vehiclePair = () -> {
            Set<Integer> r = new HashSet<>();
            for (int k = 0; k < 2; k++)
                for (int route : groupRoutes[rnd.nextInt(groupRoutes.length)])
                    for (int node : best.routes()[route]) r.add(node);
            while (r.size() > 14) r.remove(r.iterator().next());
            return r;
        };
        Supplier<Set<Integer>> timeBand = () -> {
            int lo = Integer.MAX_VALUE, hi = Integer.MIN_VALUE;
            for (int o = 0; o < n; o++)
                if (isServed(o)) {
                    lo = Math.min(lo, best.times()[o]);
                    hi = Math.max(hi, best.times()[o]);
                }
            if (lo >= hi) return random.get();
            int band = Math.max(1, (hi - lo) / 4);
            int from = lo + rnd.nextInt(Math.max(1, hi - lo - band + 1));
            Set<Integer> r = new HashSet<>();
            for (int o = 0; o < n; o++)
                if (isServed(o) && best.times()[o] >= from && best.times()[o] <= from + band)
                    r.add(o);
            return r.size() < 3 ? random.get() : r;
        };
        Supplier<Set<Integer>> vehicle = () -> {
            Set<Integer> r = new HashSet<>();
            for (int route : groupRoutes[rnd.nextInt(groupRoutes.length)])
                for (int node : best.routes()[route]) r.add(node);
            int size = r.size() + 3 + rnd.nextInt(5);
            while (r.size() < Math.min(size, n)) r.add(rnd.nextInt(n));
            return r;
        };
        Supplier<Set<Integer>> dropped = () -> {
            List<Integer> out = new ArrayList<>();
            for (int o = 0; o < n; o++) if (!isServed(o)) out.add(o);
            if (out.isEmpty()) return random.get();
            Set<Integer> r = new HashSet<>(out);
            int focal = out.get(rnd.nextInt(out.size()));
            List<Integer> served = new ArrayList<>();
            for (int o = 0; o < n; o++) if (isServed(o)) served.add(o);
            served.sort(Comparator.comparingInt(o -> h[focal][o]));
            int k = 6 + rnd.nextInt(6);
            for (int i = 0; i < served.size() && r.size() < out.size() + k; i++)
                r.add(served.get(i));
            return r;
        };
        Supplier<Set<Integer>> droppedVehicle = () -> {
            List<Integer> out = new ArrayList<>();
            for (int o = 0; o < n; o++) if (!isServed(o)) out.add(o);
            if (out.isEmpty()) return random.get();
            Set<Integer> r = new HashSet<>(out);
            int focal = out.get(rnd.nextInt(out.size()));
            int bestG = -1, bestD = Integer.MAX_VALUE;
            for (int g = 0; g < groupRoutes.length; g++) {
                boolean allowed = false;
                for (int route : groupRoutes[g])
                    if (!seq[route].isNode(focal, SeqStatus.EXCLUDED)) allowed = true;
                if (!allowed) continue;
                for (int route : groupRoutes[g])
                    for (int node : best.routes()[route])
                        if (h[focal][node] < bestD) {
                            bestD = h[focal][node];
                            bestG = g;
                        }
            }
            if (bestG >= 0)
                for (int route : groupRoutes[bestG])
                    for (int node : best.routes()[route]) r.add(node);
            return r;
        };
        // the last two are the big moves, given a larger probe budget
        return new Supplier[]{random, shaw, worst, vehiclePair, timeBand, vehicle,
                dropped, droppedVehicle};
    }
}
