import java.util.function.Predicate;
import org.maxicp.search.SearchStatistics;
import org.maxicp.search.DFSearch;
import org.maxicp.modeling.algebra.integer.IntExpression;

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
}
