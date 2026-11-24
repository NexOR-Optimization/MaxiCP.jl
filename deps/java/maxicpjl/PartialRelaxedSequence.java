package maxicpjl;

import org.maxicp.cp.engine.core.AbstractCPConstraint;
import org.maxicp.cp.engine.core.CPSeqVar;
import org.maxicp.modeling.algebra.sequence.SeqStatus;

import java.util.Set;

/**
 * LNS relaxation: re-imposes {@code orderedSequence} minus the {@code relaxed}
 * nodes as a subsequence of {@code sequence}. MaxiCP's RelaxedSequence expects
 * every node in the sequence and fails on routes visiting only some of them.
 */
public class PartialRelaxedSequence extends AbstractCPConstraint {

    private final CPSeqVar sequence;
    private final int[] orderedSequence;
    private final Set<Integer> relaxed;

    public PartialRelaxedSequence(CPSeqVar sequence, int[] orderedSequence,
                                  Set<Integer> relaxed) {
        super(sequence.getSolver());
        this.sequence = sequence;
        this.orderedSequence = orderedSequence;
        this.relaxed = relaxed;
    }

    @Override
    public void post() {
        int current = orderedSequence[0];
        for (int i = 1; i < orderedSequence.length - 1; i++) {
            int next = orderedSequence[i];
            if (!relaxed.contains(next)) {
                if (!sequence.isNode(next, SeqStatus.MEMBER))
                    sequence.insert(current, next);
                current = next;
            }
        }
    }
}
