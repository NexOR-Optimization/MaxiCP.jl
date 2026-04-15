module TestMaxiCP

using Test
import MathOptInterface as MOI
import MaxiCP

function runtests()
    for name in names(@__MODULE__; all = true)
        if startswith("$(name)", "test_")
            @testset "$(name)" begin
                getfield(@__MODULE__, name)()
            end
        end
    end
    return
end

function test_runtests()
    model = MOI.instantiate(
        MaxiCP.Optimizer,
        with_bridge_type = Float64,
    )
    config = MOI.Test.Config(
        Float64;
        exclude = Any[
            MOI.ConstraintBasisStatus,
            MOI.VariableBasisStatus,
            MOI.ConstraintName,
            MOI.VariableName,
            MOI.DualStatus,
            MOI.ConstraintDual,
            MOI.DualObjectiveValue,
            MOI.RawStatusString,
            MOI.SolveTimeSec,
            MOI.SolverVersion,
            MOI.ObjectiveBound,
            MOI.RelativeGap,
            MOI.delete,
        ],
    )
    MOI.Test.runtests(
        model,
        config;
        verbose = true,
        exclude = [
            # Delete not supported — affects all test_basic_, test_model_, test_variable_delete
            r"test_basic_",
            r"test_variable_delete",
            r"test_variable_add_variable",
            r"test_variable_add_variables",
            r"test_add_constrained_variables_vector",
            r"test_add_parameter",
            r"test_model_ordered_indices",
            r"test_model_add_constrained_variable_tuple",
            r"test_model$",
            # Continuous/float tests not applicable (integer-only solver)
            r"test_linear_",
            r"test_conic_",
            # Modification not supported
            r"test_modification_",
            # Dual-related
            r"test_DualObjectiveValue",
            r"test_solve_DualStatus",
            r"test_solve_VariableIndex_ConstraintDual",
            r"test_solve_ObjectiveBound",
            r"test_solve_TerminationStatus_DUAL_INFEASIBLE",
            r"test_solve_result_index",
            r"test_solve_conflict_",
            r"test_solve_optimize_twice",
            r"test_solve_twice",
            # CP-SAT tests beyond AllDifferent
            "test_cpsat_Cumulative",
            "test_cpsat_CountAtLeast",
            "test_cpsat_CountBelongs",
            "test_cpsat_CountDistinct",
            "test_cpsat_CountGreaterThan",
            "test_cpsat_Path",
            "test_cpsat_ReifiedAllDifferent",
            # Infeasible/unbounded detection
            r"test_infeasible_",
            r"test_unbounded_",
            # Variable solve tests
            r"test_variable_solve_",
            # Constraint tests that require solve with Float64 objectives
            r"test_constraint_ScalarAffineFunction_",
            r"test_constraint_VectorAffineFunction_",
            r"test_constraint_ZeroOne_bounds",
            # Objective tests that require unsupported features
            r"test_objective_ObjectiveFunction_VariableIndex",
            r"test_objective_ObjectiveFunction_constant",
            r"test_objective_ObjectiveFunction_duplicate_terms",
            r"test_objective_get_ObjectiveFunction_ScalarAffineFunction",
            r"test_objective_set_via_modify",
            r"test_objective_ObjectiveSense_in_ListOfModelAttributesSet",
            # SOS, quadratic, nonlinear
            r"test_quadratic_",
            r"test_nonlinear_",
            r"test_vector_nonlinear_",
            # Solve tests that may have issues
            r"test_solve_SOS2",
        ],
    )
    return
end

end  # module

TestMaxiCP.runtests()
