# Building the graph from shapefiles

DISPLACE's spatial graph (`graphsspe/coord<N>.dat` and `graph<N>.dat`) is
normally made in the editor GUI, with **Create Graph** followed by **Load
Harbours** and **Link Harbours**. None of that is in the headless simulator
this package installs. This note covers where the code lives upstream, what
was considered for running it from R, and what `build_displace_graph()` does
instead.

Upstream reference: `frabas/DISPLACE_GUI` at `96eadecb` (`v1.8.0`), read only.

## Where it lives upstream

| Step | Source |
|---|---|
| Dialog → builder options | `qtgui/mainwindow.cpp`, `on_actionCreate_Graph_triggered()` |
| Grid points | `qtgui/algo/simplegeodesiclinegraphbuilder.cpp` (Hex/Quad), `simpleplanargraphbuilder.cpp` (the "trivial" types) |
| Clip to shapefiles, triangulate, weight | `qtgui/graphbuilder_shp.cpp`, `GraphBuilder::buildGraph()` — GDAL/OGR `Clip`/`SymDifference`, CGAL constrained Delaunay, GeographicLib distances |
| Harbours | `InputFileParser::parseHarbourFile()` (`name;x;y;code`), `on_actionLink_Harbours_triggered()` |
| Write the files | `qtgui/inputfileexporter.cpp`, `InputFileExporter::exportGraph()` |

`tools/convshp.py` only reprojects a shapefile to WGS84. The GUI assumes
lon/lat input.

## Options considered

### A. Port the algorithm to R — chosen

The algorithm is only about 300 lines, and every step has an equivalent in the
R spatial stack:

| Upstream | R |
|---|---|
| GeographicLib geodesics | Vincenty's formulae on WGS84, in base R (`geod_inverse()`, `geod_direct()`); within 1 mm of the published test case |
| Hex/Quad grid generators | Direct ports: `grid_geodesic()`, `grid_planar()` |
| OGR `Clip` / `SymDifference` | `sf::st_intersects()` with s2 off, so the test is planar in lon/lat like OGR's |
| CGAL Delaunay | `sf::st_triangulate(bOnlyEdges = TRUE)` (GEOS) |
| Edge weight | `floor(d_km + 0.5)`, as `buildGraph()` does |
| Exclusion-zone edge removal | `st_intersects()` of each edge with `exclude` |

`sf` goes in Suggests, and only the graph builder needs it. This adds no
compiled code, and the binary pipeline is unchanged. It runs anywhere `sf`
installs, including the Windows and macOS CRAN binaries.

**Check before relying on it on sequoia.** `sf` needs GDAL, GEOS and PROJ at
runtime. If `library(sf)` does not already work in Positron on the server, it
can be installed from the Posit Package Manager Ubuntu 24.04 binaries. Those
still need `libgdal34`, `libgeos` and `libproj25` from apt, which means root.
A fallback that needs no root: build the graph on a laptop and copy the
`graphsspe/` files across. They are plain text.

### B. Compile upstream's `GraphBuilder` into a headless CLI — rejected

Technically this would mean a `tools/patches/graphbuilder-main.cpp` that
drives `graphbuilder_shp.cpp` and the two `algo/` files from a throwaway
checkout, built by `tools/build-displace.sh` and shipped in the payload.
Upstream stays untouched. It fails on cost:

- **Dependencies.** It needs Qt6Core (`QPointF`, `QList`, `QString`, `QDir`),
  CGAL, GDAL and GeographicLib. Bundling GDAL means PROJ, GEOS, libtiff, curl
  and the PROJ data directory. That is the same objection that already ruled
  out GDAL for the simulator, and it would grow the payload several times over.
  Qt6Core brings ICU as well.
- **The surrounding GUI code is incomplete at `96eadecb`.**
  `DisplaceModel::addGraph()`, `importHarbours()` and `getAllNodesWithin()` are
  declared in `qtgui/displacemodel.h` but defined nowhere in the tree. The
  builder itself is self-contained, but everything after it (numbering nodes,
  adding harbours, exporting) would have to be rewritten anyway.
- It would run on only one platform per build, whereas the R port runs
  anywhere `sf` does.

### C. Drive the GUI — not possible

The editor is interactive Qt with no command-line entry point for graph
creation, and the headless build excludes it on purpose.

### D. Take graphs from `DISPLACE_R_inputs` — complementary

Upstream's R routines build case-study inputs from prepared data, but not
graphs from shapefiles. Graphs there come from the GUI. They remain the model
for the other `graphsspe/coord<N>_with_<layer>.dat` files.

## How the port differs from the GUI

All of these differences are smaller than a grid step:

- **No constrained triangulation.** CGAL constrains consecutive points along a
  grid row, but on a regular grid those segments are Delaunay edges already.
  The only possible difference is a tie between a square cell's two diagonals
  (quad grids).
- **Grid spacing.** Points are spaced by equal distance along each geodesic,
  not by equal arc (`GeodesicLine::ArcPosition`). The difference is well under
  a metre.
- **Node numbering.** Node ids are contiguous, in generation order (include,
  include2, outside). Upstream numbers points before clipping and compacts the
  gaps later.
- **Unused GUI options are left out.** The "min/max links" fields are stored on
  the upstream builder but never read, and edge removal in the exclusion zone
  happens whenever an exclusion shapefile is given, regardless of its checkbox.

## Verified against a GUI-built graph

Checked on 2026-09-28 against the westcoast case study's GUI-built graphs in
`emlab-ucsb/DISPLACE-westcoast-analysis`, under
`inputs/project_base_inputs/GRAPH/`, using its own `shp/graph_area.shp`
(include) and `shp/exclusion_area.shp` (exclude):

```r
g <- build_displace_graph(
  bbox = c(-125.9199, 31.96527, -117.15335, 48.8), step_km = 4,
  include = "shp/graph_area.shp", exclude = "shp/exclusion_area.shp",
  type = "hex", method = "planar", max_edge_km = 20, a_graph = 0)
write_displace_graph(g, out, digits = 6)

h <- link_displace_harbours(g, "harbours.dat")   # GUI defaults
h$a_graph <- 1L
write_displace_graph(h, out, digits = 6)
```

| File | Result |
|---|---|
| `coord0.dat` (no harbours) | byte-identical: 18,418 nodes, same order |
| `graph0.dat` | the same 107,938 (from, to, km) edges; the from-block is byte-identical |
| `coord1.dat` (+ 21 harbours) | byte-identical |
| `graph1.dat` | the same 108,064 edges; one harbour link reads 4.92816 against the GUI's 4.92815 |

The GUI's settings were recovered from the files themselves:

- **Grid type.** Rows at constant latitude mean the planar ("HexTrivial")
  generator.
- **Step.** 4 km, from the 0.03125° row spacing (4 km × √3/2).
- **Edge limit.** 20 km, the longest edge in the file.
- **Origin.** The GUI's `xmin` was −125.9199, not the shapefile's −125.91799. A
  constant column offset pins it to [−125.919906, −125.9199].

Two differences remain:

- **Edge order within a node.** The GUI lists each node's edges in the order
  CGAL walks around the node (counterclockwise, from a start set by CGAL's
  insertion bookkeeping); this port sorts them by target. It matters a little.
  The simulator's A* router (`AStarShortestPathFinder`, over a Boost adjacency
  list filled in file order) breaks ties between equally long routes by that
  order, and whole-km weights on a regular grid make ties common. Route
  lengths, and so distances, fuel and ground choice, are unaffected. The exact
  intermediate nodes on a steaming route can differ, and so can node-level
  track outputs. That is well below DISPLACE's run-to-run noise, since its
  random generator is seeded from the clock.
- **One harbour weight's last digit.** Its length is 4.9281550016 km, just
  above the 6-digit rounding boundary. The GUI's grid, chained with
  GeographicLib rather than Vincenty, puts that node 4 µm away, at
  4.9281549974 km. The router reads weights as floats, so this is a 1 cm
  difference in one link.

**Both can be closed.** A proof of concept produced all six coord/graph files
and all 36 closure files byte-identical. It did three things. It ran the GUI's
exact CGAL loop in a 40-line helper to get the edge order. It chained the grid
with GeographicLib. And it appended harbour links as the GUI does: nearest
first for a harbour, and at the end of each sea node's list. Doing that in the
package means shipping a small compiled helper in the release payload; that is
not done yet.

The westcoast build takes about 2.5 minutes, mostly clipping 110k grid points
against the 294k-vertex polygons.

## Closures and penalties

The GUI's **Add Penalty from File** (and **on Polygon**) is ported as
`add_displace_closure()` and `write_displace_closures()`. Upstream declares
`DisplaceModel::addPenaltyToNodesByAddWeight()` in `qtgui/displacemodel.h` but
defines it nowhere in the tree. The rules were therefore recovered from
westcoast graph 2, which is graph 1 plus the five 2024 California wind lease
areas (`shp/ca_lease_areas_2024.shp`), closed at weight 500:

- **Edge penalty.** Each edge that intersects a polygon gets `weight` added,
  once per polygon it intersects. That gives 758 edges at +500 and 102 at
  +1000; the +1000 edges cross the shared side of two touching lease areas.
  An edge that only clips a polygon's corner counts too: 14 of the penalised
  edges have neither endpoint inside.
- **Closures.** One line is written per closed node and polygon, in feature
  order, for each selected month:
  `polyId nbOfDaysClosed nodeId id...`. The ids are métiers, vessel sizes or
  nations, depending on the file. `InputFileExporter::outputClosedPolyFile()`
  writes the line even when the id list is empty.

```r
g2 <- add_displace_closure(g1, "shp/ca_lease_areas_2024.shp", weight = 500,
                           days_closed = 31, months = 1:12, metiers = 0:24,
                           vessel_sizes = c(0, 1, 2, 4), nations = 0)
g2$a_graph <- 2L
write_displace_graph(g2, out, digits = 6)
write_displace_closures(g2, out)
```

Result: all 36 `*_closure_a_graph2_month*.dat` files are byte-identical, and
`graph2.dat` has every one of the 860 changed weights. The only difference is
the harbour rounding tie described above.

**Quarterly files are not written.** The simulator's
`read_metier_quarterly_closures()` and its call are commented out upstream as
deprecated. Only the monthly files are read, and only when `dyn_alloc_sce`
includes `area_monthly_closure`; then all 36 files must exist. The GUI still
writes `metier_closure_*_quarter*.dat` from `NodePenalty::q[4]`, but the code
that set those flags is commented out, so they are never initialised. In the
westcoast files, the quarter files leave out lease area 1 entirely, which
shows the effect.

## Behaviour inherited from upstream

- **Leave `max_edge_km` unset and you get very long edges.** Triangulation
  closes the convex hull, so it draws edges across bays and around headlands.
  With geodesic grids it also draws one long chord across the south edge,
  because each row is a geodesic that bows poleward. A 2° × 1.5° box at 5 km
  gets a 185 km edge. The GUI's "remove long edges" option exists for this;
  about 1.5 × the coarsest step is a good value.
- Rows are geodesics, not parallels. The grid's top and bottom edges curve
  accordingly, and a row can overshoot `xmax` by half a step.

## Usage

```r
sea  <- sf::st_read("study_area.shp")
land <- sf::st_read("coastline.shp")
ports <- data.frame(name = c("Morro Bay", "Port San Luis"),
                    lon = c(-120.85, -120.75), lat = c(35.37, 35.17),
                    harbour = 1:2)

g <- build_displace_graph(step_km = 5, include = sea, exclude = land,
                          max_edge_km = 7.5)
g <- link_displace_harbours(g, ports, max_dist_km = 15, max_links = 3)
write_displace_graph(g, "DISPLACE_input_mycase", a_graph = 1)
# then set nrow_coord = g$nrow_coord and nrow_graph = g$nrow_graph in the
# scenario file
```

## Not done yet

- The per-node layers (`coord<N>_with_landscape.dat`, bathymetry, benthos, …)
  and `code_area_for_graph<N>_points.dat`. These come from sampling rasters or
  polygons at the nodes, which is another small `sf`/`terra` step, and
  `write_displace_graph(code_area = )` already writes the last one.
- `shortPaths_*` / `min_distance_*` caches, still an open question in
  `CLAUDE.md`.
- `names_harbours.dat` from `harbour_name`.
- The GUI's other closure inputs (`metier_closure_*_quarter*`; the
  `closed_to_other_as_well` area types). The first is deprecated upstream.
