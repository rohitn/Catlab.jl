""" Algorithms on graphs based on C-sets.
"""
module GraphAlgorithms
export connected_components, connected_component_projection, connected_component_projection_bfs,
  topological_sort, transitive_reduction!, enumerate_paths

using DataStructures: Stack, DefaultDict

using ACSets
using ...Theories: dom, codom
using ..BasicGraphs
using ..PropertyGraphs: ReflexiveEdgePropertyGraph

# Connectivity
##############

""" (Weakly) connected components of a graph.

Returns a vector of vectors, which are the components of the graph.
"""
function connected_components(g::ACSet)::Vector{Vector{Int}}
  π = connected_component_projection(g)
  components = [ Int[] for c in codom(π) ]
  for v in dom(π)
    push!(components[π(v)], v)
  end
  components
end

""" Projection onto (weakly) connected components of a graph.

Returns a function in FinSet{Int} from the vertex set to the set of components.
"""
function connected_component_projection end

function connected_component_projection_bfs end
# Implemented elsewhere, where coequalizers are available.

# DAGs
######

abstract type TopologicalSortAlgorithm end
struct TopologicalSortByDFS <: TopologicalSortAlgorithm end

""" Topological sort of a directed acyclic graph.

The [depth-first search](https://en.wikipedia.org/wiki/Topological_sorting#Depth-first_search)
algorithm is adapted from the function `topological_sort_by_dfs` in Graphs.jl.
"""
function topological_sort(g::ACSet;
                          alg::TopologicalSortAlgorithm=TopologicalSortByDFS())
  topological_sort(g, alg)
end

function topological_sort(g::ACSet, ::TopologicalSortByDFS)
  vs = Int[]
  marking = fill(Unmarked, nv(g))
  for v in reverse(vertices(g))
    marking[v] == Unmarked || continue
    marking[v] = TempMarked
    stack = Stack{Int}()
    push!(stack, v)
    while !isempty(stack)
      u = first(stack)
      u_out = collect(outneighbors(g, u))
      i = findfirst(u_out) do w
        marking[w] != TempMarked || error("Graph is not acyclic: $g")
        marking[w] == Unmarked
      end
      if isnothing(i)
        marking[u] = Marked
        push!(vs, u)
        pop!(stack)
      else
        w = u_out[i]
        marking[w] = TempMarked
        push!(stack, w)
      end
    end
  end
  reverse!(vs)
end

@enum TopologicalSortDFSMarking Unmarked=0 TempMarked=1 Marked=2

""" Transitive reduction of a DAG.

The algorithm computes the longest paths in the DAGs and keeps only the edges
corresponding to longest paths of length 1. Requires a topological sort, which
is computed if it is not supplied.
"""
function transitive_reduction!(g::ACSet; sorted=nothing)
  lengths = longest_paths(g, sorted=sorted)
  transitive_edges = filter(edges(g)) do e
    lengths[tgt(g,e)] - lengths[src(g,e)] != 1
  end
  rem_edges!(g, transitive_edges)
  return g
end

""" Longest paths in a DAG.

Returns a vector of integers whose i-th element is the length of the longest
path to vertex i. Requires a topological sort, which is computed if it is not
supplied.
"""
function longest_paths(g::ACSet;
                       sorted::Union{AbstractVector{Int},Nothing}=nothing)
  if isnothing(sorted)
    sorted = topological_sort(g)
  end
  lengths = fill(0, nv(g))
  for v in sorted
    lengths[v] = mapreduce(max, inneighbors(g, v), init=0) do u
      lengths[u] + 1
    end
  end
  lengths
end

"""Enumerate all paths of an acyclic graph, indexed by src+tgt"""
function enumerate_paths(G::Graph;
                         sorted::Union{AbstractVector{Int},Nothing}=nothing
                        )::ReflexiveEdgePropertyGraph{Vector{Int}}
  sorted = isnothing(sorted) ? topological_sort(G) : sorted
  Path = Vector{Int}

  paths = [Set{Path}() for _ in 1:nv(G)] # paths that start on a particular V
  for v in reverse(sorted)
    push!(paths[v], Int[]) # add length 0 paths
    for e in incident(G, v, :src)
      push!(paths[v], [e]) # add length 1 paths
      for p in paths[G[e, :tgt]] # add length >1 paths
        push!(paths[v], vcat([e], p))
      end
    end
  end
  # Initialize output data structure with empty paths
  res = @acset ReflexiveEdgePropertyGraph{Path} begin
    V=nv(G); E=nv(G); src=1:nv(G); tgt=1:nv(G); refl=1:nv(G)
    eprops=[Int[] for _ in 1:nv(G)]
  end
  for (src, ps) in enumerate(paths)
    for p in filter(x->!isempty(x), ps)
      add_part!(res, :E; src=src, tgt=G[p[end],:tgt], eprops=p)
    end
  end
  return res
end

end
