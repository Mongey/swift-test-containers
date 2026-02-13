import Foundation

enum DependencyGraph {
    static func topologicalSort(
        containers: Set<String>,
        dependencies: [String: Set<String>]
    ) throws -> [String] {
        var inDegree: [String: Int] = [:]
        var adjacency: [String: Set<String>] = [:]

        for container in containers {
            inDegree[container] = 0
            adjacency[container] = []
        }

        for (dependent, directDependencies) in dependencies {
            guard containers.contains(dependent) else {
                throw TestContainersError.invalidDependency(
                    dependent: dependent,
                    dependency: directDependencies.sorted().first ?? "<none>",
                    reason: "Dependent container '\(dependent)' is not defined in stack"
                )
            }

            for dependency in directDependencies {
                guard containers.contains(dependency) else {
                    throw TestContainersError.invalidDependency(
                        dependent: dependent,
                        dependency: dependency,
                        reason: "Dependency '\(dependency)' is not defined in stack"
                    )
                }

                adjacency[dependency, default: []].insert(dependent)
                inDegree[dependent, default: 0] += 1
            }
        }

        var queue = inDegree
            .filter { $0.value == 0 }
            .map(\.key)
            .sorted()

        var order: [String] = []

        while let node = queue.first {
            queue.removeFirst()
            order.append(node)

            let dependents = adjacency[node, default: []].sorted()
            for dependent in dependents {
                let updatedDegree = (inDegree[dependent] ?? 0) - 1
                inDegree[dependent] = updatedDegree
                if updatedDegree == 0 {
                    insertSorted(&queue, value: dependent)
                }
            }
        }

        if order.count != containers.count {
            let cycleNodes = inDegree
                .filter { $0.value > 0 }
                .map(\.key)
                .sorted()
            throw TestContainersError.circularDependency(containers: cycleNodes)
        }

        return order
    }

    private static func insertSorted(_ array: inout [String], value: String) {
        if let index = array.firstIndex(where: { $0 > value }) {
            array.insert(value, at: index)
        } else {
            array.append(value)
        }
    }
}
