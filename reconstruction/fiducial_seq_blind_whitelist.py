"""
analysis of fiducial diffusion sequencing result without bead barcode matching
input fastq file
output collapsed barcode information
"""
import os
import time
import gzip
import argparse
import numpy as np
import mappy as mp
import pandas as pd
import editdistance
from collections import Counter
from umi_tools import UMIClusterer
from matplotlib.backends.backend_pdf import PdfPages
from helpers import *

# barcode blind - R1 is V8/V10, R2 is V9/15
def barcode_extract(fq1_file, fq2_file, r2type):
    '''
    # input: R1 and R2 fastqs
    # output: dict of barcode without matching
    '''
    aln_dict = {}
    R1_bc_list = []
    R2_bc_list = []
    alignment_stat = Counter()
    for fq1, fq2 in zip(mp.fastx_read(fq1_file, read_comment=False), mp.fastx_read(fq2_file, read_comment=False)):
        alignment_stat["total_reads"] += 1
        if alignment_stat["total_reads"] % 1000000 == 0:
            print(alignment_stat["total_reads"])
        if len(fq1[1])<46 or len(fq2[1])<46:  
            alignment_stat["Read_too_short"] += 1
            continue

        # Load R1
        R1_bc = fq1[1][0:8] + fq1[1][26:32]
        R1_bumi = fq1[1][33:41] # if R1: 32:40, if V8 or V10: 33:41
        R1_UP = fq1[1][8:26]

        # Load R2
        if r2type == 'V9':
            R2_bc = fq2[1][0:8] + fq2[1][26:32]
            R2_bumi = fq2[1][33:41]
            R2_UP = fq2[1][8:26]
            if editdistance.eval(R1_UP,'TCTTCAGCGTTCCCGAGA')>3 or editdistance.eval(R2_UP,'TCTTCAGCGTTCCCGAGA')>3:
                alignment_stat["UP_not_matched"] += 1
                continue 
        elif r2type == 'V15':
            R2_bc = fq2[1][0:14]
            R2_bumi = fq2[1][25:33]
            R2_UP = fq2[1][15:25]
            if editdistance.eval(R1_UP,'TCTTCAGCGTTCCCGAGA')>3 or editdistance.eval(R2_UP,'CTGTTTCCTG')>2:
                alignment_stat["UP_not_matched"] += 1
                continue
        else:
            assert False, f"unknown read2type ({r2type})"
        
        alignment_stat['effective_read'] += 1
        aln_dict.setdefault(R1_bc,[]).append((R2_bc, R1_bumi, R2_bumi)) 
        R1_bc_list.append(R1_bc)
        R2_bc_list.append(R2_bc)
    return aln_dict, alignment_stat, R1_bc_list, R2_bc_list
    

def umi_collapsing(cnt_dict, max_dist=1):
    """
    input: dict of barcode without matching
    output: list of barcode after collapsing
    """
    start_time = time.time()
    clusterer = UMIClusterer(cluster_method="directional")
    clustered_bc = clusterer(cnt_dict, threshold=max_dist)
    clustering_time = time.time()
    cluster_bc = [bc_group[0].decode('utf-8') for bc_group in clustered_bc]
    end_time = time.time()
    print("Clustering time: {}s".format(clustering_time-start_time))
    print("Dict creation time is: {}s".format(end_time-clustering_time))
    print("Total time is: {}s".format(end_time-start_time))
    return cluster_bc


def bc_collapsing(aln_dict, R1_bc_list, R2_bc_list, min_reads_R1, min_reads_R2, alignment_stat):
    """ 
    input: dict of barcode without matching
    output: dict of barcode after filtering and collapsing
    """
    # filter for reads and collapse to whitelist
    R1_list = [s.encode('utf-8') for s in R1_bc_list]
    R1_dict = dict(Counter(R1_list))
    R1_dict_top = {k: v for k, v in R1_dict.items() if v > min_reads_R1}
    R1_whitelist = umi_collapsing(R1_dict_top)
    print("R1 total {}, after filter {}, whitelist {}".format(len(R1_dict),len(R1_dict_top),len(R1_whitelist)))
    print("read percentage: {}".format(np.sum(list(R1_dict_top.values()))/np.sum(list(R1_dict.values()))))
    
    R2_list = [s.encode('utf-8') for s in R2_bc_list]
    R2_dict = dict(Counter(R2_list))
    R2_dict_top = {k: v for k, v in R2_dict.items() if v > min_reads_R2}
    R2_whitelist = umi_collapsing(R2_dict_top)
    print("R2 total {}, after filter {}, whitelist {}".format(len(R2_dict),len(R2_dict_top),len(R2_whitelist)))
    print("read percentage: {}".format(np.sum(list(R2_dict_top.values()))/np.sum(list(R2_dict.values()))))

    # match to whitelist
    R1_bc_matching_dict,_,_ = barcode_matching(Counter(R1_whitelist), list(set(R1_bc_list)), max_dist=1)
    R2_bc_matching_dict,_,_ = barcode_matching(Counter(R2_whitelist), list(set(R2_bc_list)), max_dist=1)

    # generate dict with matched bc
    aln_dict_new = {}
    for bc_R1 in aln_dict:
        if bc_R1 in R1_bc_matching_dict:
            for R2 in range(len(aln_dict[bc_R1])):
                bc_R2 = aln_dict[bc_R1][R2][0]
                if bc_R2 in R2_bc_matching_dict:
                    alignment_stat["after_filter_reads"] += 1
                    aln_dict_new.setdefault(R1_bc_matching_dict[bc_R1],[]).append(
                        (R2_bc_matching_dict[bc_R2],
                         aln_dict[bc_R1][R2][1],
                         aln_dict[bc_R1][R2][2]))
    return aln_dict_new, alignment_stat


def write_blind(aln_dict_new, alignment_stat, out_dir):
    # collapse for reads
    for bc in aln_dict_new:
        tmp = Counter(aln_dict_new[bc])
        aln_dict_new[bc] = tmp

    # write result to csv
    raw_f = gzip.open(os.path.join(out_dir,"blind_raw_reads_filtered.csv.gz"),"wb")
    raw_f.write(b'R1_bc,R2_bc,R1_bumi,R2_bumi,reads\n')
    for bc_R1 in aln_dict_new:
        raw_f.write(bytes('\n'.join(['{},{},{},{},{}'.format(
            bc_R1, it[0], it[1], it[2], aln_dict_new[bc_R1][it]) for it in aln_dict_new[bc_R1]])+'\n',"UTF-8"))
    raw_f.close()

    with open(os.path.join(out_dir,"blind_statistics_filtered.csv"),"w") as f:
        f.write("alignment_status,counts\n")
        for aln_stat in alignment_stat:
            f.write("{},{}\n".format(aln_stat, alignment_stat[aln_stat]) )


def get_args():
    parser = argparse.ArgumentParser(description='Process recon seq data.')
    parser.add_argument(
        "-f", "--fastqpath",
        help="path to the R1s and R2s",
        type=str,
        required=True,
    )
    parser.add_argument(
        "-f", "--outputpath",
        help="path to the output",
        type=str,
        default=".",
    )
    parser.add_argument(
        "-r2", "--read2type",
        help="input bead type of read2",
        type=str,
        required=True,
    )
    args = parser.parse_args()
    return args

if __name__ == '__main__':
    args = get_args()
    in_path = args.fastqpath ; print(f"FASTQ path: {in_path}")
    out_path = args.outputpath ; print(f"Output path: {out_path}")
    r2type = args.read2type ; print(f"read2type: {r2type}")

    print("loading files")
    fq_files = [f for f in os.listdir(in_path) if not f.startswith('.')]
    R1s = [it for it in fq_files if "R1" in it]
    R2s = [it for it in fq_files if "R2" in it]
    print(f"R1s: {R1s}")
    print(f"R2s: {R2s}")
    assert len(R1s) == len(R2s) == 1
    R1 = os.path.join(in_path, R1s[0])
    R2 = os.path.join(in_path, R2s[0])
    
    print("extracting barcode")
    aln_dict, stat, R1_bc_list, R2_bc_list = barcode_extract(R1, R2, r2type)

    if not os.path.exists(out_path):
        os.makedirs(out_path)
    
    print("creating barcode rank plots")
    qc_pdf_file = os.path.join(out_path, 'QC.pdf')
    qc_pdfs = PdfPages(qc_pdf_file)
    R1_threshold = bc_rankplot(R1_bc_list, 'R1', qc_pdfs, max_expected_barcodes=1000000)
    R2_threshold = bc_rankplot(R2_bc_list, 'R2', qc_pdfs, max_expected_barcodes=1000000)
    qc_pdfs.close()

    print(f"R1_threshold: {R1_threshold}")
    print(f"R2_threshold: {R2_threshold}")

    print("performing barcode collapsing")
    aln_dict_new, stat_new = bc_collapsing(aln_dict, R1_bc_list, R2_bc_list, min_reads_R1=R1_threshold, min_reads_R2=R2_threshold, alignment_stat = stat)
    
    print("writing results")
    write_blind(aln_dict_new, stat_new, out_path)
