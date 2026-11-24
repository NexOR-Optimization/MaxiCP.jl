package maxicpjl;

import org.maxicp.cp.engine.core.AbstractCPConstraint;
import org.maxicp.cp.engine.core.CPIntVar;
import org.maxicp.cp.engine.core.CPSeqVar;
import org.maxicp.modeling.algebra.sequence.SeqStatus;
import org.maxicp.state.StateInt;
import org.maxicp.util.exception.InconsistencyException;

/**
 * MathOptVRP.RouteExtremities on one route: every member visits either before all
 * the other visited nodes or after all of them. The visit times order the route,
 * services or travels being positive; the side of each member is committed once
 * the other is impossible.
 */
public class FirstOrLast extends AbstractCPConstraint {

    private static final int UNKNOWN = 0, FIRST = 1, LAST = 2;

    private final CPSeqVar route;
    private final int[] members;
    private final int[] others;
    private final CPIntVar[] time;
    private final StateInt[] side;

    public FirstOrLast(CPSeqVar route, int[] members, int[] others, CPIntVar[] time) {
        super(route.getSolver());
        this.route = route;
        this.members = members;
        this.others = others;
        this.time = time;
        this.side = new StateInt[members.length];
        for (int i = 0; i < members.length; i++)
            side[i] = getSolver().getStateManager().makeStateInt(UNKNOWN);
    }

    @Override
    public void post() {
        for (int p : members) time[p].propagateOnBoundChange(this);
        for (int q : others) time[q].propagateOnBoundChange(this);
        route.propagateOnRequire(this);
        route.propagateOnExclude(this);
        propagate();
    }

    @Override
    public void propagate() {
        for (int i = 0; i < members.length; i++) {
            int p = members[i];
            if (!route.isNode(p, SeqStatus.REQUIRED)) continue;
            int sd = side[i].value();
            if (sd == UNKNOWN) {
                boolean canFirst = true, canLast = true;
                for (int q : others) {
                    if (!route.isNode(q, SeqStatus.REQUIRED)) continue;
                    if (time[p].min() + 1 > time[q].max()) canFirst = false;
                    if (time[q].min() + 1 > time[p].max()) canLast = false;
                }
                if (!canFirst && !canLast) throw InconsistencyException.INCONSISTENCY;
                if (!canFirst) side[i].setValue(sd = LAST);
                else if (!canLast) side[i].setValue(sd = FIRST);
            }
            if (sd == FIRST) {
                int minMax = Integer.MAX_VALUE;
                for (int q : others) {
                    if (!route.isNode(q, SeqStatus.REQUIRED)) continue;
                    time[q].removeBelow(time[p].min() + 1);
                    minMax = Math.min(minMax, time[q].max());
                }
                if (minMax != Integer.MAX_VALUE) time[p].removeAbove(minMax - 1);
            } else if (sd == LAST) {
                int maxMin = Integer.MIN_VALUE;
                for (int q : others) {
                    if (!route.isNode(q, SeqStatus.REQUIRED)) continue;
                    time[q].removeAbove(time[p].max() - 1);
                    maxMin = Math.max(maxMin, time[q].min());
                }
                if (maxMin != Integer.MIN_VALUE) time[p].removeBelow(maxMin + 1);
            }
        }
    }
}
