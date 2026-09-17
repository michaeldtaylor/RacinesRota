# SearchKernel.ps1 -- the depth-first pattern search, in C#.
#
# Everything else in this engine stays in PowerShell, where it is readable and easy to
# change. This one piece does not: it visits millions of nodes, and PowerShell's per-call
# scriptblock overhead dominates it by two orders of magnitude. Compiling it with Add-Type
# needs no .NET SDK -- PowerShell carries its own Roslyn -- so the project still builds and
# runs from a bare PowerShell 7 install.
#
# The kernel knows nothing about rota rules. It is handed pre-filtered pattern domains and
# a capacity model, and it returns the cheapest complete assignments it can find. Every
# rule lives in Constraints.ps1, which is also what finally scores the winner.

Set-StrictMode -Version Latest

function Initialize-RotaSearchKernel {
    <#
    .SYNOPSIS
        Compile the search kernel once per session.
    #>
    [CmdletBinding()]
    param()
    if ('Racines.RotaSearch' -as [type]) { return }

    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Numerics;

namespace Racines
{
    public sealed class RotaSolution
    {
        public double Cost;
        public int[] Masks;      // indexed by variable; -1 where the variable is not ours
    }

    public sealed class RotaSearchResult
    {
        public List<RotaSolution> Solutions = new List<RotaSolution>();
        public bool TimedOut;
        public long Nodes;
    }

    /// <summary>
    /// Depth-first search over per-variable pattern domains under a levelled capacity model.
    ///
    /// Coverage is held as one bitmask per (level, week): level L holds the services covered
    /// at least L+1 times. Placing a person cascades a single mask upwards through the levels,
    /// so the work per node is independent of how many shifts the pattern contains.
    /// </summary>
    public static class RotaSearch
    {
        public static RotaSearchResult Run(
            int[][] domains,          // [variable][i] -> pattern mask
            double[][] domainCosts,   // [variable][i] -> soft cost of that pattern
            int[][] varWeeks,         // [variable][] -> zero-based week indexes
            int[] counts,             // [variable] -> required shift count
            int[][] cap,              // [level][week] -> mask of services still wanting L+1 more
            int levels,
            int[] order,              // variable indexes, search order
            int weekCount,
            int varCount,
            bool derivable,           // may the final variable be derived from leftover capacity?
            int lastIdx,
            int lastWeek,             // zero-based
            int topN,
            long deadlineTicks)
        {
            var result = new RotaSearchResult();
            var state = new State
            {
                Domains = domains, DomainCosts = domainCosts, VarWeeks = varWeeks,
                Counts = counts, Cap = cap, Levels = levels, Order = order,
                WeekCount = weekCount, VarCount = varCount, Derivable = derivable,
                LastIdx = lastIdx, LastWeek = lastWeek, TopN = topN,
                Deadline = deadlineTicks, Result = result
            };

            state.Cov = new int[levels * weekCount];
            state.NotCap = new int[levels * weekCount];
            for (int L = 0; L < levels; L++)
                for (int w = 0; w < weekCount; w++)
                    state.NotCap[L * weekCount + w] = (~cap[L][w]) & 0x3FFF;

            state.Chosen = new int[varCount];
            for (int i = 0; i < varCount; i++) state.Chosen[i] = -1;

            // Membership index for the derived final variable, plus its cost lookup.
            if (derivable)
            {
                state.LastLookup = new Dictionary<int, double>();
                var dom = domains[lastIdx];
                var dc = domainCosts[lastIdx];
                for (int i = 0; i < dom.Length; i++) state.LastLookup[dom[i]] = dc[i];
            }

            // One save buffer per depth, so undoing never allocates.
            int maxWeeks = 1;
            for (int v = 0; v < varWeeks.Length; v++) if (varWeeks[v].Length > maxWeeks) maxWeeks = varWeeks[v].Length;
            state.Save = new int[order.Length][];
            for (int d = 0; d < order.Length; d++) state.Save[d] = new int[maxWeeks * levels];
            state.Tmp = new int[levels];

            Recurse(state, 0, 0.0);

            state.Result.Solutions.Sort((a, b) => a.Cost.CompareTo(b.Cost));
            if (state.Result.Solutions.Count > topN)
                state.Result.Solutions.RemoveRange(topN, state.Result.Solutions.Count - topN);
            return result;
        }

        private sealed class State
        {
            public int[][] Domains; public double[][] DomainCosts; public int[][] VarWeeks;
            public int[] Counts; public int[][] Cap; public int Levels; public int[] Order;
            public int WeekCount; public int VarCount; public bool Derivable;
            public int LastIdx; public int LastWeek; public int TopN;
            public long Deadline; public RotaSearchResult Result;
            public int[] Cov; public int[] NotCap; public int[] Chosen; public int[][] Save; public int[] Tmp;
            public Dictionary<int, double> LastLookup;
            public bool Aborted;
        }

        private static void Emit(State s, double cost)
        {
            var masks = new int[s.VarCount];
            Array.Copy(s.Chosen, masks, s.VarCount);
            s.Result.Solutions.Add(new RotaSolution { Cost = cost, Masks = masks });

            // Keep only the best while searching, so a roster with millions of valid
            // schedules does not exhaust memory before it finishes.
            if (s.Result.Solutions.Count > s.TopN * 4)
            {
                s.Result.Solutions.Sort((a, b) => a.Cost.CompareTo(b.Cost));
                s.Result.Solutions.RemoveRange(s.TopN, s.Result.Solutions.Count - s.TopN);
            }
        }

        private static void Recurse(State s, int depth, double cost)
        {
            if (s.Aborted) return;
            if ((++s.Result.Nodes & 0xFFFF) == 0 && DateTime.UtcNow.Ticks > s.Deadline)
            {
                s.Aborted = true;
                s.Result.TimedOut = true;
                return;
            }

            // The final variable need not be searched when it owns a single week that must
            // come out exactly full: its pattern is whatever capacity is left over.
            if (s.Derivable && depth == s.Order.Length - 1)
            {
                int wi = s.LastWeek;
                for (int L = 1; L < s.Levels; L++)
                    if ((s.Cap[L][wi] & ~s.Cov[(L - 1) * s.WeekCount + wi] & 0x3FFF) != 0) return;

                int forced = 0;
                for (int L = 0; L < s.Levels; L++)
                    forced |= s.Cap[L][wi] & ~s.Cov[L * s.WeekCount + wi] & 0x3FFF;

                if (BitOperations.PopCount((uint)forced) != s.Counts[s.LastIdx]) return;
                double lastCost;
                if (!s.LastLookup.TryGetValue(forced, out lastCost)) return;

                s.Chosen[s.LastIdx] = forced;
                Emit(s, cost + lastCost);
                s.Chosen[s.LastIdx] = -1;
                return;
            }

            if (depth == s.Order.Length) { Emit(s, cost); return; }

            int v = s.Order[depth];
            int[] dom = s.Domains[v];
            double[] dcost = s.DomainCosts[v];
            int[] weeks = s.VarWeeks[v];
            int[] save = s.Save[depth];

            for (int k = 0; k < dom.Length; k++)
            {
                if (s.Aborted) return;
                int mask = dom[k];
                int committed = 0;
                bool ok = true;

                for (int wIdx = 0; wIdx < weeks.Length; wIdx++)
                {
                    int wi = weeks[wIdx];
                    // Already at the top level: no room for another head.
                    if ((s.Cov[(s.Levels - 1) * s.WeekCount + wi] & mask) != 0) { ok = false; break; }

                    for (int L = s.Levels - 1; L >= 1; L--)
                        s.Tmp[L] = s.Cov[L * s.WeekCount + wi] | (s.Cov[(L - 1) * s.WeekCount + wi] & mask);
                    s.Tmp[0] = s.Cov[wi] | mask;

                    bool bad = false;
                    for (int L = 0; L < s.Levels; L++)
                        if ((s.Tmp[L] & s.NotCap[L * s.WeekCount + wi]) != 0) { bad = true; break; }
                    if (bad) { ok = false; break; }

                    for (int L = 0; L < s.Levels; L++)
                    {
                        save[committed * s.Levels + L] = s.Cov[L * s.WeekCount + wi];
                        s.Cov[L * s.WeekCount + wi] = s.Tmp[L];
                    }
                    committed++;
                }

                if (ok)
                {
                    s.Chosen[v] = mask;
                    Recurse(s, depth + 1, cost + dcost[k]);
                    s.Chosen[v] = -1;
                }

                for (int c = committed - 1; c >= 0; c--)
                {
                    int wi = weeks[c];
                    for (int L = 0; L < s.Levels; L++)
                        s.Cov[L * s.WeekCount + wi] = save[c * s.Levels + L];
                }
            }
        }
    }
}
'@
}
