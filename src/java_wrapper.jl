# Java type aliases for MaxiCP modeling layer.
# Only provides convenience definitions for use in the MOI wrapper.

## Model
const ModelDispatcher = @jimport org.maxicp.ModelDispatcher
const MFactory = @jimport org.maxicp.modeling.Factory
const ConcreteCPModel = @jimport org.maxicp.cp.modeling.ConcreteCPModel

## Variable types (modeling layer)
const JIntVar = @jimport org.maxicp.modeling.IntVar
const JBoolVar = @jimport org.maxicp.modeling.BoolVar

## Expression types
const IntExpression = @jimport org.maxicp.modeling.algebra.integer.IntExpression
const BoolExpression = @jimport org.maxicp.modeling.algebra.bool.BoolExpression
const JConstraint = @jimport org.maxicp.modeling.Constraint

## Search types
const DFSearch = @jimport org.maxicp.search.DFSearch
const SearchStatistics = @jimport org.maxicp.search.SearchStatistics
const JSearches = @jimport org.maxicp.search.Searches
const JSupplier = @jimport java.util.function.Supplier

## Objective types
const SymObjective = @jimport org.maxicp.modeling.symbolic.Objective

## Helper types
const SearchHelper = @jimport SearchHelper
const JPredicate = @jimport java.util.function.Predicate
