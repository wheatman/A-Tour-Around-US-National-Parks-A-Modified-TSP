#  This Source Code Form is subject to the terms of the Mozilla Public
#  License, v. 2.0. If a copy of the MPL was not distributed with this
#  file, You can obtain one at http://mozilla.org/MPL/2.0/.
#############################################################################
# this code is based on the work of Iain Dunning, Joey Huchette, Miles Lubin, and contributors
# for an implementation of a standard TSP solver which can be found at the link below
# JuMP
# An algebraic modelling langauge for Julia
# See http://github.com/JuliaOpt/JuMP.jl
#############################################################################
# tsp.jl
#
# Solves the travelling salesman problem using integer programming and
# lazy generation of the subtour elimination constraints.
#############################################################################


using JuMP
using Gurobi
using Base.Test

#used to replace the norm function to get the distances between each park
function GPSToDist(lat1, long1, lat2, long2)
  R = 6371000 # metres
  a = sin((lat2-lat1)/2) * sin((lat2-lat1)/2) +  cos(lat1) * cos(lat2) *   sin((long2-long1)/2) * sin((long2-long1)/2)
  c = 2 * atan2(sqrt(a), sqrt(1-a))
  return R * c
end

# extractTour
# Given a n-by-n matrix representing the solution to an undirected TSP,
# extract the tour as a vector
# Input:
#  n        Number of cities
#  sol      n-by-n 0-1 symmetric matrix representing solution
# Output:
#  tour     n+1 length vector of tour, starting and ending at 1
function extractTour(n, sol)
    tour = [1]  # Start at city 1 always
    cur_city = 1
    while true
        # Look for first arc out of current city
        for j = 1:n
            if sol[cur_city,j] >= 1-1e-6
                # Found next city
                push!(tour, j)
                # Don't ever use this arc again
                sol[cur_city, j] = 0.0
                sol[j, cur_city] = 0.0
                # Move to next city
                cur_city = j
                break
            end
        end
        # If we have come back to 1, stop
        if cur_city == 1
            break
        end
    end  # end while
    return tour
end

# findSubtour
# Given a n-by-n matrix representing solution to the relaxed
# undirected TSP problem, find a set of nodes belonging to a subtour
# Input:
#  n        Number of cities
#  sol      n-by-n 0-1 symmetric matrix representing solution
# Outputs:
#  subtour  n length vector of booleans, true iff in a particular subtour
#  subtour_length   Number of cities in subtour (if n, no subtour found)
function findSubtour(n, sol)
    # Initialize to no subtour
    subtour = fill(false,n)
    # Always start looking at city 1
    cur_city = 1
    subtour[cur_city] = true
    subtour_length = 1
    while true
        # Find next node that we haven't yet visited
        found_city = false
        for j = 1:n
            if !subtour[j]
                if sol[cur_city, j] >= 1 - 1e-6
                    # Arc to unvisited city, follow it
                    cur_city = j
                    subtour[j] = true
                    found_city = true
                    subtour_length += 1
                    break  # Move on to next city
                end
            end
        end
        if !found_city
            # We are done
            break
        end
    end
    return subtour, subtour_length
end

# solveTSP
# Given a matrix of city locations, solve the TSP
# Inputs:
#   n       Number of cities
#   cities  n-by-2 matrix of (x,y) city locations
# Output:
#   path    Vector with order to cities are visited in
function solveTSP(n, cities, maxdis)

    # Calculate pairwise distance matrix
    dist = zeros(n, n)
    prizes = zeros(1,n)
    for i = 1:n
      prizes[i] = cities[i,3]
    end
    for i = 1:n
        for j = i:n
            d = GPSToDist(cities[i,1], cities[i,2], cities[j,1], cities[j,2])
            dist[i,j] = d
            dist[j,i] = d
        end
    end

     # Create a model that will use Gurobi to solve
    # We need to tell Gurobi we are using lazy constraints
    m = Model(solver=GurobiSolver())

    # x[i,j] is 1 iff we travel between i and j, 0 otherwise
    # Although we define all n^2 variables, we will only use
    # the upper triangle
    @defVar(m, x[1:n,1:n], Bin)
    @defVar(m, v[1:n], Bin)
    @defVar(m, n1>=0)
    @addConstraint(m, n1 == sum{v[i],i=1:n})


    # maximize the values of the prizes
    @setObjective(m, Max, sum{prizes[i]*v[i], i=1:n})
    @addConstraint(m,sum{dist[i,j]*x[i,j], i=1:n,j=i:n}<=maxdis)
    # Make x_ij and x_ji be the same thing (undirectional)
    # Don't allow self-arcs
    for i = 1:n
        @addConstraint(m, x[i,i] == 0)
        @addConstraint(m, v[i] ==sum{x[i,j],j=1:n}/2)
        for j = (i+1):n
            @addConstraint(m, x[i,j] == x[j,i])
        end
    end

    # We must enter and leave every city we visit once and only once
    for i = 1:n
        @addConstraint(m, sum{x[i,j], j=1:n} == 2*v[i])
    end

    function subtour(cb)
        # Optional: display tour starting at city 1
        println("----\nInside subtour callback")
        println("Current tour starting at city 1:")
        print(extractTour(n, getValue(x)))

        # Find any set of cities in a subtour
        subtour, subtour_length = findSubtour(n, getValue(x))

        if subtour_length == getValue(n1)
            # This "subtour" is actually all cities that are visited, so we are done
            println("Solution visits all cities")
            println("----")
            return
        end

        # Subtour found - add lazy constraint
        # We will build it up piece-by-piece
        arcs_from_subtour = AffExpr()

        for i = 1:n
            if !subtour[i]
                # If this city isn't in subtour, skip it
                continue
            end
            # Want to include all arcs from this city, which is in
            # the subtour, to all cities not in the subtour
            for j = 1:n
                if i == j
                    # Self-arc
                    continue
                elseif subtour[j]
                    # Both ends in same subtour
                    continue
                else
                    # j isn't in subtour
                    arcs_from_subtour += x[i,j]
                end
            end
        end

        # Add the new subtour elimination constraint we built
        println("Adding subtour elimination cut")
        println("----")
        addLazyConstraint(cb, arcs_from_subtour >= 2)
    end  # End function subtour

    # Solve the problem with our cut generator
    setLazyCallback(m, subtour)
    solve(m)

    # Return best tour
    return extractTour(n, getValue(x))
end  # end solveTSP

cities = readcsv("C:\\Users\\username\\Google_Drive\\15.053_Project\\data.csv")
n = size(cities,1)
maxdis = 10000000

tour = solveTSP(n, cities, maxdis)

println("Solution: ")
println(tour)

print("[")
for i=tour
    print("(")
    print(cities[i,:1])
    print(",")
    print(cities[i,:2])
    print(")")
    print(",")
end
println("]")
println(length(tour))
