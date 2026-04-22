import java.util.function.Predicate;
import org.maxicp.search.SearchStatistics;
import org.maxicp.search.DFSearch;
import org.maxicp.modeling.algebra.integer.IntExpression;
import org.maxicp.modeling.ModelProxy;
import org.maxicp.cp.modeling.ConcreteCPModel;
import org.maxicp.cp.engine.core.CPIntVar;

public class SearchHelper {
    public static Predicate<SearchStatistics> stopAfterFirstSolution() {
        return stats -> stats.numberOfSolutions() >= 1;
    }

    /**
     * Solve and capture the first solution's variable values.
     * Returns an array of the min values of each expression at the first solution,
     * or null if no solution is found.
     */
    public static int[] solveAndCapture(DFSearch dfs, IntExpression[] vars) {
        int[] result = new int[vars.length];
        boolean[] found = {false};
        dfs.onSolution(() -> {
            if (!found[0]) {
                found[0] = true;
                for (int i = 0; i < vars.length; i++) {
                    result[i] = vars[i].min();
                }
            }
        });
        SearchStatistics stats = dfs.solve(s -> s.numberOfSolutions() >= 1);
        if (stats.numberOfSolutions() > 0) {
            return result;
        }
        return null;
    }

    /**
     * Optimize and capture the best solution's variable values.
     * Returns an array of the min values of each expression at the best solution,
     * or null if no solution is found.
     */
    public static int[] optimizeAndCapture(DFSearch dfs, org.maxicp.modeling.symbolic.Objective obj, IntExpression[] vars) {
        int[] result = new int[vars.length];
        boolean[] found = {false};
        dfs.onSolution(() -> {
            found[0] = true;
            for (int i = 0; i < vars.length; i++) {
                result[i] = vars[i].min();
            }
        });
        SearchStatistics stats = dfs.optimize(obj);
        if (stats.numberOfSolutions() > 0) {
            return result;
        }
        return null;
    }

    /**
     * Post a SubCircuit constraint on the given variables.
     * Must be called AFTER cpInstantiate() since SubCircuit is a raw CP
     * constraint not available in the modeling layer.
     *
     * @param modelProxy the ModelDispatcher (must be instantiated)
     * @param vars the successor variables (modeling layer)
     */
    public static void postSubCircuit(org.maxicp.ModelDispatcher modelProxy, IntExpression[] vars) {
        ConcreteCPModel cp = (ConcreteCPModel) modelProxy.getConcreteModel();
        CPIntVar[] cpVars = new CPIntVar[vars.length];
        for (int i = 0; i < vars.length; i++) {
            cpVars[i] = cp.getCPVar(vars[i]);
        }
        cp.solver.post(new org.maxicp.cp.engine.constraints.SubCircuit(cpVars));
    }
}
