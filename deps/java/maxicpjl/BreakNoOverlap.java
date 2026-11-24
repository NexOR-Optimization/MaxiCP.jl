package maxicpjl;

import org.maxicp.cp.engine.core.AbstractCPConstraint;
import org.maxicp.cp.engine.core.CPBoolVar;
import org.maxicp.cp.engine.core.CPIntVar;
import org.maxicp.cp.engine.core.CPSeqVar;
import org.maxicp.modeling.algebra.sequence.SeqStatus;
import org.maxicp.util.exception.InconsistencyException;

/**
 * The break of a MathOptVRP.VehicleSchedule: when {@code taken}, no service,
 * travel or reload of the vehicle's trips overlaps
 * {@code [breakStart, breakStart + length)}; an activity that would overlap it
 * starts after it.
 *
 * Each service is a disjunction with the break, with bound reasoning on both. Once
 * the start of the break is fixed, an earliest-schedule walk along the trips raises
 * the lower bounds of their times, so that an insertion leaving no room for the
 * break fails at once, as LunchBreak does.
 */
public class BreakNoOverlap extends AbstractCPConstraint {

    private final CPSeqVar[] trips;
    private final int n;               // nodes 0..n-1 may be visited
    private final CPIntVar[] time;
    private final int[] service;
    private final CPBoolVar taken;
    private final CPIntVar breakStart;
    private final int length;
    private final int[][][] travel;    // [trip] node x node
    private final int reloadFixed;
    private final int[] reload;
    private final int[] buffer;

    public BreakNoOverlap(CPSeqVar[] trips, int n, CPIntVar[] time, int[] service,
                          CPBoolVar taken, CPIntVar breakStart, int length,
                          int[][][] travel, int reloadFixed, int[] reload) {
        super(breakStart.getSolver());
        this.trips = trips;
        this.n = n;
        this.time = time;
        this.service = service;
        this.taken = taken;
        this.breakStart = breakStart;
        this.length = length;
        this.travel = travel;
        this.reloadFixed = reloadFixed;
        this.reload = reload;
        this.buffer = new int[time.length];
    }

    @Override
    public void post() {
        taken.propagateOnFix(this);
        breakStart.propagateOnBoundChange(this);
        for (int o = 0; o < n; o++) time[o].propagateOnBoundChange(this);
        for (CPSeqVar s : trips) {
            time[s.start()].propagateOnBoundChange(this);
            time[s.end()].propagateOnBoundChange(this);
            s.propagateOnInsert(this);
            s.propagateOnRequire(this);
            s.propagateOnExclude(this);
        }
        propagate();
    }

    @Override
    public void propagate() {
        if (!taken.isTrue()) return;
        for (int o = 0; o < n; o++) {
            if (service[o] == 0) continue;
            boolean on = false, possible = false;
            for (CPSeqVar s : trips) {
                if (s.isNode(o, SeqStatus.REQUIRED)) on = true;
                if (!s.isNode(o, SeqStatus.EXCLUDED)) possible = true;
            }
            if (!possible) continue;
            boolean canBefore = time[o].min() + service[o] <= breakStart.max();
            boolean canAfter = time[o].max() >= breakStart.min() + length;
            if (on) {
                if (!canBefore && !canAfter) throw InconsistencyException.INCONSISTENCY;
                if (!canAfter) {
                    time[o].removeAbove(breakStart.max() - service[o]);
                    breakStart.removeBelow(time[o].min() + service[o]);
                } else if (!canBefore) {
                    time[o].removeBelow(breakStart.min() + length);
                    breakStart.removeAbove(time[o].max() - length);
                }
            } else if (!canBefore && !canAfter) {
                for (CPSeqVar s : trips)
                    if (!s.isNode(o, SeqStatus.EXCLUDED)) s.exclude(o);
            }
        }
        if (breakStart.isFixed()) walk();
    }

    /** The end of an activity of {@code duration} from {@code start}, after the break. */
    private long after(long start, int duration, int br, int bl) {
        if (duration > 0 && start < bl && start + duration > br) start = bl;
        return start + duration;
    }

    private void walk() {
        final int br = breakStart.min(), bl = br + length;
        long end = Long.MIN_VALUE;   // end of the previous trip
        for (int t = 0; t < trips.length; t++) {
            CPSeqVar s = trips[t];
            int members = s.nNode(SeqStatus.MEMBER);
            long cur = time[s.start()].min();
            if (t > 0) {
                int r = 0;
                if (members > 2) {
                    r = reloadFixed;
                    s.fillNode(buffer, SeqStatus.MEMBER);
                    for (int i = 0; i < members; i++)
                        if (buffer[i] < n) r += reload[buffer[i]];
                }
                cur = Math.max(cur, after(end, r, br, bl));
            }
            int prev = -1;
            for (int node = s.start(); ; node = s.memberAfter(node)) {
                if (prev >= 0)
                    cur = Math.max(after(cur, travel[t][prev][node], br, bl), time[node].min());
                int svc = node < n ? service[node] : 0;
                if (svc > 0 && cur < bl && cur + svc > br) cur = bl;
                if (cur > time[node].max()) throw InconsistencyException.INCONSISTENCY;
                time[node].removeBelow((int) cur);
                cur = Math.max(cur, time[node].min()) + svc;
                prev = node;
                if (node == s.end()) break;
            }
            end = time[s.end()].min();
        }
    }
}
