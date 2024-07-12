using CSV
using FASTX
using Plots
using Peaks: findminima
using CodecZlib
using PDFmerger
using StatsBase
using IterTools: product
using DataFrames
using StringViews
using LinearAlgebra: dot
using Combinatorics: combinations
using Distributions: pdf, Exponential

# Load the command-line arguments
if length(ARGS) != 2
    error("Usage: julia recon-count.jl fastq_path out_path")
end
fastq_path = ARGS[1]
println("FASTQ path: "*fastq_path)
@assert isdir(fastq_path) "FASTQ path not found"
@assert !isempty(readdir(fastq_path)) "FASTQ path is empty"
out_path = ARGS[2]
println("Output path: "*out_path)
Base.Filesystem.mkpath(out_path)
@assert isdir(out_path) "Output path not created"

# Load the FASTQ paths
fastqs = readdir(fastq_path, join=true)
R1s = filter(s -> occursin("_R1_", s), fastqs) ; println("R1s: ", basename.(R1s))
R2s = filter(s -> occursin("_R2_", s), fastqs) ; println("R2s: ", basename.(R2s))
@assert length(R1s) == length(R2s) > 0
@assert [replace(R1, "_R1_"=>"", count=1) for R1 in R1s] == [replace(R2, "_R2_"=>"", count=1) for R2 in R2s]

# Validate the FASTQ sequence lengths
function fastq_seq_len(path)
    return(path |> open |> GzipDecompressorStream |> FASTQ.Reader |> first |> FASTQ.sequence |> length)
end
@assert length(unique([fastq_seq_len(R1) for R1 in R1s])) == 1 "WARNING: R1s have different FASTQ sequence lengths - proceed only if you are sure they have the same read structure"
@assert length(unique([fastq_seq_len(R2) for R2 in R2s])) == 1 "WARNING: R2s have different FASTQ sequence lengths - proceed only if you are sure they have the same read structure"

# UMI matching+compressing methods
const px = [convert(UInt32, 4^i) for i in 0:(9-1)]
function UMItoindex(UMI::StringView{SubArray{UInt8, 1, Vector{UInt8}, Tuple{UnitRange{Int64}}, true}})::UInt32
    return(dot(px, (codeunits(UMI).>>1).&3))
end
const bases = ['A','C','T','G'] # MUST NOT change this order
function indextoUMI(i::UInt32)::String15
    return(String15(String([bases[(i>>n)&3+1] for n in 0:2:16])))
end

function listHDneighbors(str, hd, charlist = ['A','C','G','T','N'])::Set{String}
    res = Set{String}()
    for inds in combinations(1:length(str), hd)
        chars = [str[i] for i in inds]
        pools = [setdiff(charlist, [char]) for char in chars]
        prods = product(pools...)
        for prod in prods
            s = str
            for (i, c) in zip(inds, prod)
                s = s[1:i-1]*string(c)*s[i+1:end]
            end
            push!(res,s)
        end
    end
    return(res)
end
const umi_homopolymer_whitelist = Set{String15}(reduce(union, [listHDneighbors(str, i) for str in [c^9 for c in ["A","C","G","T"]] for i in 0:2]))

function get_R2_V9(record::FASTX.FASTQ.Record)
    sb2_1 = FASTQ.sequence(record, 1:8)
    up2 = FASTQ.sequence(record, 9:26)
    sb2_2 = FASTQ.sequence(record, 27:33)
    umi2 = FASTQ.sequence(record, 34:42)
    return sb2_1, sb2_2, up2, umi2
end
function get_R2_V15(record::FASTX.FASTQ.Record)
    sb2_1 = FASTQ.sequence(record, 1:8)
    sb2_2 = FASTQ.sequence(record, 9:15)
    up2 = FASTQ.sequence(record, 16:25)
    umi2 = FASTQ.sequence(record, 26:34)
    return sb2_1, sb2_2, up2, umi2
end
const get_R2 = Ref{Function}()

# Determine the R2 bead type
function learn_R2type(R2)
    iter = R2 |> open |> GzipDecompressorStream |> FASTQ.Reader
    UPseq9 = String31("TCTTCAGCGTTCCCGAGA")
    UPseq15 = String15("CTGTTTCCTG")
    s9 = 0 ; s15 = 0
    for (i, record) in enumerate(iter)
        i > 100000 ? break : nothing
        s9  += FASTQ.sequence(record, 9:26)  == UPseq9
        s15 += FASTQ.sequence(record, 16:25) == UPseq15
    end
    println("V9: ", s9, " V15: ", s15)
    return(s9 >= s15 ? "V9" : "V15")
end

println("R1 bead type: V8/V10")
const UP1 = "TCTTCAGCGTTCCCGAGA"
const UP1_whitelist = Set{String31}(reduce(union, [listHDneighbors(UP1, i) for i in 0:3]))

println("Learning the R2 bead type")
res_list = [learn_R2type(R2) for R2 in R2s]
if all(x -> x == "V9", res_list)
    println("R2 bead type: V9")
    const UP2 = "TCTTCAGCGTTCCCGAGA"
    const UP2_whitelist = Set{String31}(reduce(union, [listHDneighbors(UP2, i) for i in 0:3]))
    get_R2[] = get_R2_V9
elseif all(x -> x == "V15", res_list)
    println("R2 bead type: V15")
    const UP2 = "CTGTTTCCTG"
    const UP2_whitelist = Set{String15}(reduce(union, [listHDneighbors(UP2, i) for i in 0:2]))
    get_R2[] = get_R2_V15
else
    error("Error: The R2 bead type is not consistent ($res_list)")
end

####################################################################################################

print("Reading FASTQs... ") ; flush(stdout)

# Read the FASTQs
function process_fastqs(R1s, R2s)
    sb1_dictionary = Dict{String15, UInt32}() # sb1 -> sb1_i
    sb2_dictionary = Dict{String15, UInt32}() # sb2 -> sb2_i
    mat = Dict{Tuple{UInt32, UInt32, UInt32, UInt32}, UInt32}() # (sb1_i, umi1_i, sb2_i, umi2_i) -> reads
    metadata = Dict("reads"=>0, "R1_tooshort"=>0, "R2_tooshort"=>0, "R1_N_UMI"=>0, "R2_N_UMI"=>0, "R1_homopolymer_UMI"=>0, "R2_homopolymer_UMI"=>0, "R1_no_UP"=>0, "R2_no_UP"=>0, "reads_filtered"=>0)

    for fastqpair in zip(R1s, R2s)
        it1 = fastqpair[1] |> open |> GzipDecompressorStream |> FASTQ.Reader
        it2 = fastqpair[2] |> open |> GzipDecompressorStream |> FASTQ.Reader
        for record in zip(it1, it2)
            metadata["reads"] += 1

            skip = false
            if length(FASTQ.sequence(record[1])) < 42
                metadata["R1_tooshort"] += 1
                skip = true
            end
            if length(FASTQ.sequence(record[2])) < 34
                metadata["R2_tooshort"] += 1
                skip = true
            end
            if skip
                continue
            end

            sb1_1 = FASTQ.sequence(record[1], 1:8)
            up1 = FASTQ.sequence(record[1], 9:26)
            sb1_2 = FASTQ.sequence(record[1], 27:33)
            umi1 = FASTQ.sequence(record[1], 34:42)

            sb2_1, sb2_2, up2, umi2 = get_R2[](record[2])

            skip = false
            if occursin('N', umi1)
                metadata["R1_N_UMI"] += 1
                skip = true
            end
            if occursin('N', umi2) 
                metadata["R2_N_UMI"] += 1
                skip = true
            end
            if in(umi1, umi_homopolymer_whitelist)
                metadata["R1_homopolymer_UMI"] += 1
                skip = true
            end
            if in(umi2, umi_homopolymer_whitelist)
                metadata["R2_homopolymer_UMI"] += 1
                skip = true
            end
            if !in(up1, UP1_whitelist)
                metadata["R1_no_UP"] += 1
                skip = true
            end
            if !in(up2, UP2_whitelist)
                metadata["R2_no_UP"] += 1
                skip = true
            end
            if skip
                continue
            end

            # update counts
            sb1_i = get!(sb1_dictionary, sb1_1*sb1_2, length(sb1_dictionary) + 1)
            sb2_i = get!(sb2_dictionary, sb2_1*sb2_2, length(sb2_dictionary) + 1)
            umi1_i = UMItoindex(umi1)
            umi2_i = UMItoindex(umi2)
            key = (sb1_i, umi1_i, sb2_i, umi2_i)
            mat[key] = get(mat, key, 0) + 1
            metadata["reads_filtered"] += 1
        end
    end

    sb1_whitelist = DataFrame(sb1 = collect(String15, keys(sb1_dictionary)), sb1_i = collect(UInt32, values(sb1_dictionary)))
    sb2_whitelist = DataFrame(sb2 = collect(String15, keys(sb2_dictionary)), sb2_i = collect(UInt32, values(sb2_dictionary)))
    sort!(sb1_whitelist, :sb1_i)
    sort!(sb2_whitelist, :sb2_i)
    @assert sb1_whitelist.sb1_i == 1:size(sb1_whitelist, 1)
    @assert sb2_whitelist.sb2_i == 1:size(sb2_whitelist, 1)
    
    metadata["umis_filtered"] = length(mat)
    return(mat, sb1_whitelist.sb1, sb2_whitelist.sb2, metadata)
end
mat, sb1_whitelist, sb2_whitelist, metadata = process_fastqs(R1s, R2s)

println("done") ; flush(stdout) ; GC.gc()

####################################################################################################

print("Computing barcode whitelist... ") ; flush(stdout)

# Create plots and determine cutoff
function umi_density_plot(table, R)
    x = collect(keys(table))
    y = collect(values(table))
    perm = sortperm(x)
    x = x[perm]
    y = y[perm]

    # Compute the KDE
    lx_s = 0:0.001:ceil(maximum(log10.(x)), digits=3)
    ly_s = []
    for lx_ in lx_s
        weights = [pdf(Exponential(0.05), abs(lx_ - lx)) for lx in log10.(x)]
        kde = sum(log10.(y) .* weights) / sum(weights)
        push!(ly_s, kde)
    end

    # Find the flattest point
    mins = lx_s[findminima(ly_s).indices] |> sort
    filter!(x -> x > 1, mins)
    if length(mins) > 0
        uc = round(10^mins[1])
    else
        println("WARNING: no local min found for $R, selecting flattest point along curve")
        i = argmin(abs.(diff(ly_s[1000:min(3000,length(lx_s))])))
        uc = round(10^lx_s[1000-1+i])
    end

    # Create an elbow plot
    p = plot(x, y, seriestype = :scatter, xscale = :log10, yscale = :log10, 
             xlabel = "Number of UMI", ylabel = "Frequency",
             markersize = 3, markerstrokewidth = 0.1,
             title = "$R UMI Count Distribution", titlefont = 10, guidefont = 8, label = "Barcodes")
    plot!(p, (10).^lx_s, (10).^ly_s, seriestype = :line, label="KDE")
    vline!(p, [uc], linestyle = :dash, color = :red, label = "UMI cutoff")
    xticks!(p, [10^i for i in 0:ceil(log10(maximum(x)))])
    yticks!(p, [10^i for i in 0:ceil(log10(maximum(y)))])
    return(p, uc)
end
function remove_intermediate(x, y)
    m = (y .!= vcat(y[2:end], NaN)) .| (y .!= vcat(NaN, y[1:end-1]))
    x = x[m] ; y = y[m]
    return(x, y)
end
function elbow_plot(y, uc, R)
    sort!(y, rev=true)
    x = 1:length(y)
    bc = count(e -> e >= uc, y)
    
    xp, yp = remove_intermediate(x, y)
    p = plot(xp, yp, seriestype = :line, xscale = :log10, yscale = :log10,
         xlabel = "$R Spatial Barcode Rank", ylabel = "UMI Count", 
         title = "$R Spatial Barcode Elbow Plot", titlefont = 10, guidefont = 8, label = "Barcodes")
    hline!(p, [uc], linestyle = :dash, color = :red, label = "UMI cutoff")
    vline!(p, [bc], linestyle = :dash, color = :green, label = "SB cutoff")
    xticks!(p, [10^i for i in 0:ceil(log10(maximum(xp)))])
    yticks!(p, [10^i for i in 0:ceil(log10(maximum(yp)))])
    return(p, bc)
end

tab1 = countmap([key[1] for key in keys(mat)])
tab2 = countmap([key[3] for key in keys(mat)])

p1, uc1 = umi_density_plot(tab1 |> values |> countmap, "R1")
p3, uc2 = umi_density_plot(tab2 |> values |> countmap, "R2")

p2, bc1 = elbow_plot(tab1 |> values |> collect, uc1, "R1")
p4, bc2 = elbow_plot(tab2 |> values |> collect, uc2, "R2")

p = plot(p1, p2, p3, p4, layout = (2, 2), size=(7*100, 8*100))
savefig(p, joinpath(out_path, "elbows.pdf"))

metadata["R1_umicutoff"] = uc1
metadata["R2_umicutoff"] = uc2
metadata["R1_barcodes"] = bc1
metadata["R2_barcodes"] = bc2

println("done") ; flush(stdout) ; GC.gc()

####################################################################################################

print("Matching to barcode whitelist... ") ; flush(stdout)

wl1 = Set{UInt32}([k for (k, v) in tab1 if v >= uc1]) ; @assert length(wl1) == bc1
wl2 = Set{UInt32}([k for (k, v) in tab2 if v >= uc2]) ; @assert length(wl2) == bc2

function match_barcode(mat, wl1, wl2)
    matching_metadata = Dict("R1_exact"=>0, "R1_none"=>0,
                             "R2_exact"=>0, "R2_none"=>0)
    
    for key in keys(mat)
        if key[1] in wl1
            matching_metadata["R1_exact"] += 1
        else
            matching_metadata["R1_none"] += 1
            delete!(mat, key)
        end
        if key[3] in wl2
            matching_metadata["R2_exact"] += 1
        else
            matching_metadata["R2_none"] += 1
            delete!(mat, key)
        end
    end
    return mat, matching_metadata
end
mat, matching_metadata = match_barcode(mat, wl1, wl2)
metadata["umis_matched"] = length(mat)

println("done") ; flush(stdout) ; GC.gc()

####################################################################################################

print("Counting UMIs... ") ; flush(stdout)

function count_umis(mat)
    umi_dict = Dict{Tuple{UInt32, UInt32}, UInt32}()
    for key in keys(mat)
        pair = (key[1], key[3])
        pop!(mat, key)
        umi_dict[pair] = get(umi_dict, pair, 0) + 1
    end
    df = DataFrame(sb1_i = UInt32[], sb2_i = UInt32[], umi = UInt32[])
    for key in keys(umi_dict)
        value = pop!(umi_dict, key)
        push!(df, (key[1], key[2], value))
    end
    return(df)
end
df = count_umis(mat)

println("done") ; flush(stdout) ; GC.gc()

####################################################################################################

print("Writing output... ") ; flush(stdout)

# Normalize the barcode indexes
m1 = sort(collect(Set(df.sb1_i)))
m2 = sort(collect(Set(df.sb2_i)))
dict1 = Dict{UInt32, UInt32}(value => index for (index, value) in enumerate(m1))
dict2 = Dict{UInt32, UInt32}(value => index for (index, value) in enumerate(m2))
sb1_whitelist_short = sb1_whitelist[m1]
sb2_whitelist_short = sb2_whitelist[m2]
sb1_new = [dict1[k] for k in df.sb1_i]
sb2_new = [dict2[k] for k in df.sb2_i]
@assert sb1_whitelist[df.sb1_i] == sb1_whitelist_short[sb1_new]
@assert sb2_whitelist[df.sb2_i] == sb2_whitelist_short[sb2_new]
df.sb1_i = sb1_new
df.sb2_i = sb2_new

# Create total counts of UMI per bead
df1 = combine(groupby(df, :sb1_i), :umi => sum => :umi)
sort!(df1, :sb1_i)
@assert df1.sb1_i == collect(1:nrow(df1))
df2 = combine(groupby(df, :sb2_i), :umi => sum => :umi)
sort!(df2, :sb2_i)
@assert df2.sb2_i == collect(1:nrow(df2))

# Write UMI histograms
function plot_umi_histogram(vec, bead)
    hist = fit(Histogram, vec, nbins=100)
    bin_heights = hist.weights
    bin_centers = (hist.edges[1][1:end-1] .+ hist.edges[1][2:end]) ./ 2
    bar(bin_centers, log10.(bin_heights), legend = false,
        xlabel = "log10 umi", ylabel = "log10 beads", title = "Histogram of total umi per $bead",
        titlefont = 10, guidefont = 8, xticks = [i for i in 0:10], yticks = [i for i in 0:10],
        linewidth = 0, linealpha = 0, fillcolor = :gray50)
end
p1 = plot_umi_histogram(log10.(df1[!, :umi]), "sb1")
p2 = plot_umi_histogram(log10.(df2[!, :umi]), "sb2")
p = plot(p1, p2, layout = (2, 1), size=(7*100, 8*100))
savefig(p, joinpath(out_path, "histograms.pdf"))

# Write the metadata
function f(num)
    num = string(num)
    num = reverse(join([reverse(num)[i:min(i+2, end)] for i in 1:3:length(num)], ","))
    return(num)
end
function d(num1, num2)
    f(num1)*" ("*string(round(num1/num2*100, digits=2))*"%"*")"
end
m = metadata
mm = matching_metadata
data = [
("", "Total reads", ""),
("", f(m["reads"]), ""),
("R1 too short", "", "R2 too short"),
(d(m["R1_tooshort"],m["reads"]), "", d(m["R2_tooshort"],m["reads"])),
("R1 degen UMI", "", "R2 degen UMI"),
(d(m["R1_homopolymer_UMI"],m["reads"]), "", d(m["R2_homopolymer_UMI"],m["reads"])),
("R1 LQ UMI" , "", "R2 LQ UMI"),
(d(m["R1_N_UMI"],m["reads"]), "", d(m["R2_N_UMI"],m["reads"])),
("R1 no UP", "", "R2 no UP"),
(d(m["R1_no_UP"],m["reads"]), "", d(m["R2_no_UP"],m["reads"])),
("", "Filtered reads", ""),
("", d(m["reads_filtered"], m["reads"]), ""),
("", "Sequencing saturation", ""),
("", string(round((1 - (m["umis_filtered"] / m["reads_filtered"]))*100, digits=1))*"%", ""),
("", "Filtered UMIs", ""),
("", f(m["umis_filtered"]), ""),
("R1 UMI cutoff: ", "", "R2 UMI cutoff"),
(f(m["R1_umicutoff"]), "", f(m["R2_umicutoff"])),
("R1 Barcodes", "R2:R1 ratio", "R2 Barcodes"),
(f(m["R1_barcodes"]), string(round(m["R2_barcodes"]/m["R1_barcodes"],digits=2)), f(m["R2_barcodes"])),
("R1 exact matches", "", "R2 exact matches"),
(d(mm["R1_exact"],m["umis_filtered"]), "", d(mm["R2_exact"],m["umis_filtered"])),
("R1 none matches", "", "R2 none matches"),
(d(mm["R1_none"],m["umis_filtered"]), "", d(mm["R2_none"],m["umis_filtered"])),
("", "Matched UMIs", ""),
("", d(m["umis_matched"], m["umis_filtered"]), ""),
]
p = plot(xlim=(0, 4), ylim=(0, 26+1), framestyle=:none, size=(7*100, 8*100),
         legend=false, xticks=:none, yticks=:none)
for (i, (str1, str2, str3)) in enumerate(data)
    annotate!(p, 1, 26 - i + 1, text(str1, :center, 12))
    annotate!(p, 2, 26 - i + 1, text(str2, :center, 12))
    annotate!(p, 3, 26 - i + 1, text(str3, :center, 12))
end
hline!(p, [12.5], linestyle = :solid, color = :black)
savefig(p, joinpath(out_path, "metadata.pdf"))

merge_pdfs([joinpath(out_path,"elbows.pdf"),
            joinpath(out_path,"metadata.pdf"),
            joinpath(out_path,"histograms.pdf")],
            joinpath(out_path,"QC.pdf"), cleanup=true)

@assert isempty(intersect(keys(metadata), keys(matching_metadata)))
meta_df = DataFrame([Dict(:key => k, :value => v) for (k,v) in merge(metadata, matching_metadata)])
sort!(meta_df, :key) ; meta_df = select(meta_df, :key, :value)
CSV.write(joinpath(out_path,"metadata.csv"), meta_df, writeheader=false)

@assert length(df1.umi) == length(sb1_whitelist_short)
open(GzipCompressorStream, joinpath(out_path,"sb1.csv.gz"), "w") do file
    for line in zip(sb1_whitelist_short, df1.umi)
        write(file, line[1] * "," * string(line[2]) * "\n")
    end
end
@assert length(df2.umi) == length(sb2_whitelist_short)
open(GzipCompressorStream, joinpath(out_path,"sb2.csv.gz"), "w") do file
    for line in zip(sb2_whitelist_short, df2.umi)
        write(file, line[1] * "," * string(line[2]) * "\n")
    end
end
open(GzipCompressorStream, joinpath(out_path,"matrix.csv.gz"), "w") do file
    CSV.write(file, df, writeheader=false)
end

println("done!") ; flush(stdout) ; GC.gc()

@assert all(f -> isfile(joinpath(out_path, f)), ["matrix.csv.gz", "sb1.csv.gz", "sb2.csv.gz", "metadata.csv", "QC.pdf"])
