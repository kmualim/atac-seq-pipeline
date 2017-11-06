# ENCODE DCC ATAC-Seq/DNase-Seq pipeline
# Author: Jin Lee (leepc12@gmail.com)

workflow atac {
	# IMPORTANT NOTE on specifying input files in input.json:

	# 1) For DNase-Seq, set "bam2ta.disable_tn5_shift"=true

	# 2) Pipeline can start from any type of genome data 
	# (fastq, bam, nodup_bam, ta)
	# WDL currently does not allow optional arrays in workflow level
	# so DO NOT remove fastqs, adapters, bams, nodup_bams and tas in input.json
	# also DO NOT remove adapters from input.json even if not starting from fastqs
	# choose one of them to start with but set others as []

	# 3) fastqs is 3-dimensional array to allow merging of fastqs 
	# per replicate/endedness
	# 	1st dimension: replicate id
	# 	2nd dimension: merge id (will reduce after merging)
	# 	3rd dimension: R1, R2 (single ended or paired end)
	# for SE, length of 3rd dimension must be 1 [R1]
	# for PE, length of 3rd dimension must be 2 [R1, R2]

	# 4) other types are just 1-dimensional arrays
	# 	1st dimension: replicate id
	
	# 5) structure of adapters must match with that of fastqs	
	# if no adapters are given then set adapters = [] in input.json
	# if only some adapters are known then specify them in adapters and
	# leave other entries empty ("") while keeping the same structure as in fastqs
	# all specified/non-empty adapters will be trimmed without auto detection
	
	# 6) set "trim_adapter.auto_detect_adapter"=true 
	# to automatically detect/trim adapters for empty entries in adapters
	# there will be no auto detection for non-empty entries in adapters
	# if adapters==[], all adapters will be detected/trimmed

	# mandatory input files
	Array[Array[Array[String]]] fastqs 
								# [rep_id][merge_id][end_id]
								# 	after merging, it will reduce to 
								# 	[rep_id][end_id]
	Array[String] bams 			# [rep_id] if starting from bams
	Array[String] nodup_bams 	# [rep_id] if starting from filtered bams
	Array[String] tas 			# [rep_id] if starting from tag-aligns

	# mandaory adapters
	Array[Array[Array[String]]] adapters 
								# [rep_id][merge_id][end_id]
	# mandatory genome param
	File genome_tsv 		# reference genome data TSV file including
							# all important genome specific data file paths
							# and parameters
	Boolean paired_end 		# endedness of sample

	# mandatory resource
	Int cpu 				# total number of concurrent threads to process sample
							# this is a rough estimate. more threads can be used
							# depending on the process hierachy/tree of subtasks
							# must be >=4 and multiples of number of replicates
	# optional resource (only for SGE and SLURM)
							# name of SGE queue or SLURM partition
							# all sub-tasks of pipeline will be sumitted to two queues
	String? queue_hard 		# queue for hard/long multi-threaded tasks 
							# (trim_adapter, bowtie2, filter, bam2ta, macs2)
	String? queue_short 	# queue for easy/short tasks (all others)

	# optional but important
	Boolean? true_rep_only 	# disable all analyses for pseudo replicates
							# naive-overlap and IDR will also be disabled
	Int? multimapping 		# multimapping reads

	# optional for MACS2
	Int? cap_num_peak 		# cap number of raw peaks called from MACS2
	Float? pval_thresh 		# p.value threshold
	Int? smooth_win 		# size of smoothing window

	# optional for IDR
	Boolean? enable_idr		# enable IDR analysis on raw peaks
	Float? idr_thresh		# IDR threshold

	# optional metadata
 	String? name 			# name of sample
	String? desc 			# description for sample
	String? accession_id 	# ENCODE accession ID of sample

	# OTHER IMPORTANT mandatory/optional parameters are declared in task level

	# make genome data map
	Map[String,String] genome = read_map(genome_tsv)

	# determin input file type and num_rep (number of replicates)
	call inputs {
		input : 
			fastqs = fastqs,
			bams = bams,
			nodup_bams = nodup_bams,
			tas = tas,
	}

	# pipeline starts here (parallelized for each replicate)
	scatter(i in range(inputs.num_rep)) { 
		if (inputs.type=='fastq') {
			# trim adapters
			call trim_adapter {
				input:
					fastqs = fastqs[i],
					adapters = if length(adapters)>0 
							then adapters[i] else [],
					paired_end = paired_end,
					cpu = cpu/inputs.num_rep,
					queue = queue_hard,
			}
			# merge fastqs from technical replicates
			call merge_fastq {
				input: 
					fastqs = trim_adapter.trimmed_fastqs,
					queue = queue_short,
			}
			# align trimmed/merged fastqs with bowtie2
			call bowtie2 {
				input:
					idx_tar = genome["bowtie2_idx_tar"],
					fastqs = merge_fastq.merged_fastqs,
					paired_end = paired_end,
					multimapping = multimapping,
					cpu = cpu/inputs.num_rep,
					queue = queue_hard,
			}
		}
		if (inputs.type=='fastq' || inputs.type=='bam') {
			# filter/dedup bam
			call filter {
				input:
					bam = if defined(bowtie2.bam) 
							then bowtie2.bam else bams[i],
					paired_end = paired_end,
					multimapping = multimapping,
					cpu = cpu/inputs.num_rep,
					queue = queue_hard,
			}
		}
		if (inputs.type=='fastq' || inputs.type=='bam' ||
			inputs.type=='nodup_bam') {
			# convert bam to tagalign and subsample it if necessary
			call bam2ta {
				input:
					bam = if defined(filter.nodup_bam) 
							then filter.nodup_bam else nodup_bams[i],
					paired_end = select_first([paired_end,true]),
					cpu = cpu/inputs.num_rep,
					queue = queue_hard,
			}
		}
		# subsample tagalign (non-mito) and cross-correlation analysis
		call xcor {
			input:
				ta = if defined(bam2ta.ta) 
						then bam2ta.ta else tas[i],
				paired_end = select_first([paired_end,true]),
				cpu = cpu/inputs.num_rep,
				queue = queue_hard,
		}
		if ( !select_first([true_rep_only,false]) ) {
			# make two self pseudo replicates per true replicate
			call spr {
				input:
					ta = if defined(bam2ta.ta) 
							then bam2ta.ta else tas[i],
					paired_end = select_first([paired_end,true]),
					queue = queue_short,
			}
		}
		# call peaks on tagalign
		call macs2 {
			input:
				ta = if defined(bam2ta.ta) 
						then bam2ta.ta else tas[i],
				gensz = genome["gensz"],
				chrsz = genome["chrsz"],
				cap_num_peak = cap_num_peak,
				pval_thresh = pval_thresh,
				smooth_win = smooth_win,
				make_signal = true,
				queue = queue_hard,
		}
		# filter out peaks with blacklist
		call blacklist_filter as bfilt_macs2 {
			input:
				peak = macs2.npeak,
				blacklist = genome["blacklist"],				
				queue = queue_short,
		}
	}

	if ( inputs.num_rep>1 ) {
		# pool tagaligns from true/pseudo replicates
		call pool_ta {
			input :
				tas = select_first([bam2ta.ta,tas]),
				queue = queue_short,
		}
		if ( !select_first([true_rep_only,false]) ) {
			call pool_ta as pool_ta_pr1 {
				input :
					tas = spr.ta_pr1,
					queue = queue_short,
			}
			call pool_ta as pool_ta_pr2 {
				input :
					tas = spr.ta_pr2,
					queue = queue_short,
			}
		}
		# call peaks on pooled replicate
		call macs2 as macs2_pooled {
			input:
				ta = pool_ta.ta_pooled,
				gensz = genome["gensz"],
				chrsz = genome["chrsz"],
				cap_num_peak = cap_num_peak,
				pval_thresh = pval_thresh,
				smooth_win = smooth_win,
				make_signal = true,
				queue = queue_hard,
		}
		call blacklist_filter as bfilt_macs2_pooled {
			input:
				peak = macs2_pooled.npeak,
				blacklist = genome["blacklist"],
				queue = queue_short,
		}
	}
	if ( !select_first([true_rep_only,false]) ) {
		# call peaks on 1st pseudo replicated tagalign 
		scatter(ta in spr.ta_pr1) {
			call macs2 as macs2_pr1 {
				input:
					ta = ta,
					gensz = genome["gensz"],
					chrsz = genome["chrsz"],
					cap_num_peak = cap_num_peak,
					pval_thresh = pval_thresh,
					smooth_win = smooth_win,
					queue = queue_hard,
			}
			call blacklist_filter as bfilt_macs2_pr1 {
				input:
					peak = macs2_pr1.npeak,
					blacklist = genome["blacklist"],
					queue = queue_short,
			}
		}
 		# call peaks on 2nd pseudo replicated tagalign 
		scatter(ta in spr.ta_pr2) {
			call macs2 as macs2_pr2 {
				input:
					ta = ta,
					gensz = genome["gensz"],
					chrsz = genome["chrsz"],
					cap_num_peak = cap_num_peak,
					pval_thresh = pval_thresh,
					smooth_win = smooth_win,
					queue = queue_hard,
			}
			call blacklist_filter as bfilt_macs2_pr2 {
				input:
					peak = macs2_pr2.npeak,
					blacklist = genome["blacklist"],
					queue = queue_short,
			}
		}
		if ( inputs.num_rep>1 ) {
			# call peaks on 1st pooled pseudo replicates
			call macs2 as macs2_ppr1 {
				input:
					ta = pool_ta_pr1.ta_pooled,
					gensz = genome["gensz"],
					chrsz = genome["chrsz"],
					cap_num_peak = cap_num_peak,
					pval_thresh = pval_thresh,
					smooth_win = smooth_win,
					queue = queue_hard,
			}
			call blacklist_filter as bfilt_macs2_ppr1 {
				input:
					peak = macs2_ppr1.npeak,
					blacklist = genome["blacklist"],
					queue = queue_short,
			}
			# call peaks on 2nd pooled pseudo replicates
			call macs2 as macs2_ppr2 {
				input:
					ta = pool_ta_pr2.ta_pooled,
					gensz = genome["gensz"],
					chrsz = genome["chrsz"],
					cap_num_peak = cap_num_peak,
					pval_thresh = pval_thresh,
					smooth_win = smooth_win,
					queue = queue_hard,
			}
			call blacklist_filter as bfilt_macs2_ppr2 {
				input:
					peak = macs2_ppr2.npeak,
					blacklist = genome["blacklist"],
					queue = queue_short,
			}
		}
	}

	# generate every pair of true replicates
	if ( inputs.num_rep>1 ) {
		call pair_gen { 
			input : num_rep = inputs.num_rep
		}
	}

	# Naive overlap on every pair of true replicates
	if ( inputs.num_rep>1 ) {
		scatter( pair in pair_gen.pairs ) {
			call overlap {
				input : 
					prefix = "rep"+(pair[0]+1)+
							"-rep"+(pair[1]+1),
					peak1 = macs2.npeak[(pair[0])],
					peak2 = macs2.npeak[(pair[1])],
					peak_pooled = macs2_pooled.npeak,
					queue = queue_short,
			}
			call blacklist_filter as bfilt_overlap {
				input:
					peak = overlap.overlap_peak,
					blacklist = genome["blacklist"],
					queue = queue_short,
			}
		}
	}
	if ( !select_first([true_rep_only,false]) ) {
		# Naive overlap on pseduo replicates
		scatter( i in range(inputs.num_rep) ) {
			call overlap as overlap_pr {
				input : 
					prefix = "rep"+(i+1)+"pr",
					peak1 = macs2_pr1.npeak[i],
					peak2 = macs2_pr2.npeak[i],
					peak_pooled = macs2.npeak[i],
					queue = queue_short,
			}
			call blacklist_filter as bfilt_overlap_pr {
				input:
					peak = overlap_pr.overlap_peak,
					blacklist = genome["blacklist"],
					queue = queue_short,
			}
		}
		if ( inputs.num_rep>1 ) {
			# Naive overlap on pooled pseudo replicates
			call overlap as overlap_ppr {
				input : 
					prefix = "ppr",
					peak1 = macs2_ppr1.npeak,
					peak2 = macs2_ppr2.npeak,
					peak_pooled = macs2_pooled.npeak,
					queue = queue_short,
			}
			call blacklist_filter as bfilt_overlap_ppr {
				input:
					peak = overlap_ppr.overlap_peak,
					blacklist = genome["blacklist"],
					queue = queue_short,
			}
		}
		# reproducibility QC for overlapping peaks
		call reproducibility as reproducibility_overlap {
			input:
				peaks = select_first(
					bfilt_overlap.filtered_peak,[]),
				peaks_pr = bfilt_overlap_pr.filtered_peak,
				peak_ppr = bfilt_overlap_ppr.filtered_peak,
				queue = queue_short,
		}
	}

	if ( select_first([enable_idr,false]) ) {
		if ( inputs.num_rep>1 ) {
			scatter( pair in pair_gen.pairs ) {
				# IDR on every pair of true replicates
				call idr {
					input : 
						prefix = "rep"+(pair[0]+1)
								+"-rep"+(pair[1]+1),
						peak1 = macs2.npeak[(pair[0])],
						peak2 = macs2.npeak[(pair[1])],
						peak_pooled = macs2_pooled.npeak,
						idr_thresh = idr_thresh,
						queue = queue_short,
				}
				call blacklist_filter as bfilt_idr {
					input:
						peak = idr.idr_peak,
						blacklist = genome["blacklist"],
						queue = queue_short,
				}
			}
		}
		if ( !select_first([true_rep_only,false]) ) {
			# IDR on pseduo replicates
			scatter( i in range(inputs.num_rep) ) {
				call idr as idr_pr {
					input : 
						prefix = "rep"+(i+1)+"pr",
						peak1 = macs2_pr1.npeak[i],
						peak2 = macs2_pr2.npeak[i],
						peak_pooled = macs2.npeak[i],
						idr_thresh = idr_thresh,
						queue = queue_short,
				}
				call blacklist_filter as bfilt_idr_pr {
					input:
						peak = idr_pr.idr_peak,
						blacklist = genome["blacklist"],
						queue = queue_short,
				}		
			}
			if ( inputs.num_rep>1 ) {
				call idr as idr_ppr {
					input : 
						prefix = "ppr",
						peak1 = macs2_ppr1.npeak,
						peak2 = macs2_ppr2.npeak,
						peak_pooled = macs2_pooled.npeak,
						idr_thresh = idr_thresh,
						queue = queue_short,
				}
				call blacklist_filter as bfilt_idr_ppr {
					input:
						peak = idr_ppr.idr_peak,
						blacklist = genome["blacklist"],
						queue = queue_short,
				}
			}
			# reproducibility QC for IDR peaks
			call reproducibility as reproducibility_idr {
				input:
					peaks = select_first(
						bfilt_idr.filtered_peak,[]),
					peaks_pr = bfilt_idr_pr.filtered_peak,
					peak_ppr = bfilt_idr_ppr.filtered_peak,
					queue = queue_short,
			}
		}
	}
}

# genomic tasks
task trim_adapter { # detect/trim adapter
	# parameters from workflow
	Array[Array[File]] fastqs 		# [merge_id][end_id]
	Array[Array[String]] adapters 	# [merge_id][end_id]
	Boolean paired_end
	# mandatory
	Boolean auto_detect_adapter		# automatically detect/trim adapters
	# optional
	Int? min_trim_len 		# minimum trim length for cutadapt -m
	Float? err_rate			# Maximum allowed adapter error rate 
							# for cutadapt -e	
	# resource
	Int? cpu
	String? queue

	command {
		python $(which encode_dcc_trim_adapter.py) \
			${write_tsv(fastqs)} \
			${"--adapters " + write_tsv(adapters)} \
			${if select_first([paired_end,false])
				then "--paired-end" else ""} \
			${if select_first([auto_detect_adapter,false])
				then "--auto-detect-adapter" else ""} \
			${"--min-trim-len " + min_trim_len} \
			${"--err-rate " + err_rate} \
			${"--nth " + cpu}
	}
	output {		
		Array[Array[File]] trimmed_fastqs = read_tsv("out.tsv")
				# trimmed_fastqs[merge_id][end_id]
	}
	runtime {
		cpu : "${select_first([cpu,1])}"
		queue : queue
	}
}

task merge_fastq { # merge fastqs
	Array[Array[File]] fastqs # fastqs[merge_id][end_id]
	# resource
	String? queue

	command {
		python $(which encode_dcc_merge_fastq.py) \
			${write_tsv(fastqs)}
	}
	output {
		# merged_fastqs[end_id]
		Array[File] merged_fastqs = read_lines("out.txt")
	}
	runtime {
		queue : queue
	}
}

task bowtie2 {
	# parameters from workflow
	File idx_tar 		# reference bowtie2 index tar
	Array[File] fastqs 	# [end_id]
	Boolean paired_end
	Int? multimapping
	# optional
	String? score_min 	# min acceptable alignment score func
						# w.r.t read length
	# resource
	Int? cpu
	Int? mem_mb
	Int? time_hr
	String? queue

	command {
		python $(which encode_dcc_bowtie2.py) \
			${idx_tar} \
			${sep=' ' fastqs} \
			${if select_first([paired_end,false])
				then "--paired-end" else ""} \
			${"--multimapping " + multimapping} \
			${"--score-min " + score_min} \
			${"--nth " + cpu}
	}
	output {
		File bam = glob("*.bam")[0]
		File bai = glob("*.bai")[0]
		File align_log = glob("*.align.log")[0]
		File flagstat_qc = glob("*.flagstat.qc")[0]
	}
	runtime {
		cpu : "${select_first([cpu,1])}"
		memory : "${select_first([mem_mb,'100'])} MB"
		time : "${select_first([time_hr,1])}"
		queue : queue
	}
}

task filter {
	# parameters from workflow
	File bam
	Boolean paired_end
	Int? multimapping
	# optional
	String? dup_marker 			# picard.jar MarkDuplicates or sambamba markdup
	Int? mapq_thresh			# threshold for low MAPQ reads removal
	Boolean? no_dup_removal 	# no dupe reads removal when filtering BAM
								# dup.qc and pbc.qc will not be generated
								# nodup_bam in the output is filtered bam 
								# with dupes
	# resource
	Int? cpu
	Int? mem_mb
	Int? time_hr
	String? queue

	command {
		python $(which encode_dcc_filter.py) \
			${bam} \
			${if select_first([paired_end,false])
				then "--paired-end" else ""} \
			${"--multimapping " + multimapping} \
			${"--dup-marker " + dup_marker} \
			${"--mapq-thresh " + mapq_thresh} \
			${if select_first([no_dup_removal,false])
				then "--no-dup-removal" else ""} \
			${"--nth " + cpu}			
	}
	output {
		File nodup_bam = glob("*.bam")[0]
		File nodup_bai = glob("*.bai")[0]
		File flagstat_qc = glob("*.flagstat.qc")[0]
		Array[File] dup_qc = glob("*.dup.qc")
		Array[File] pbc_qc = glob("*.pbc.qc")
	}

	runtime {
		cpu : "${select_first([cpu,1])}"
		memory : "${select_first([mem_mb,'100'])} MB"
		time : "${select_first([time_hr,1])}"
		queue : queue
	}
}

task bam2ta {
	# parameters from workflow
	File bam
	Boolean paired_end
	# optional
	Boolean? disable_tn5_shift 	# no tn5 shifting for dnase-seq
	String? regex_grep_v_ta 	# Perl-style regular expression pattern 
                        		# to remove matching reads from TAGALIGN
	Int? subsample 				# number of reads to subsample TAGALIGN
								# this affects all downstream analysis
	# resource
	Int? cpu
	String? queue

	command {
		python $(which encode_dcc_bam2ta.py) \
			${bam} \
			${if select_first([paired_end,false])
				then "--paired-end" else ""} \
			${if select_first([disable_tn5_shift,false])
				then "--disable-tn5-shift" else ""} \
			${"--regex-grep-v-ta " +"'"+regex_grep_v_ta+"'"} \
			${"--subsample " + subsample} \
			${"--nth " + cpu}
	}
	output {
		File ta = glob("*.tagAlign.gz")[0]
	}
	runtime {
		cpu : "${select_first([cpu,1])}"
		queue : queue
	}
}

task spr { # make two self pseudo replicates
	# parameters from workflow
	File ta
	Boolean paired_end
	# resource
	String? queue

	command {
		python $(which encode_dcc_spr.py) \
			${ta} \
			${if select_first([paired_end,false])
				then "--paired-end" else ""}
	}
	output {
		File ta_pr1 = glob("*.pr1.tagAlign.gz")[0]
		File ta_pr2 = glob("*.pr2.tagAlign.gz")[0]
	}
	runtime {
		queue : queue
	}
}

task pool_ta {
	# parameters from workflow
	Array[File] tas
	# resource
	String? queue

	command {
		python $(which encode_dcc_pool_ta.py) \
			${sep=' ' tas}
	}
	output {
		File ta_pooled = glob("*.tagAlign.gz")[0]
	}
	runtime {
		queue : queue
	}
}

task xcor {
	# parameters from workflow
	File ta
	Boolean paired_end
	# optional
	Int? subsample 		# number of reads to subsample TAGALIGN
						# this will be used for xcor only
						# will not affect any downstream analysis
	# resource
	Int? cpu
	String? queue

	command {
		python $(which encode_dcc_xcor.py) \
			${ta} \
			${if select_first([paired_end,false])
				then "--paired-end" else ""} \
			${"--subsample " + select_first(subsample,25000000)} \
			--speak=0 \
			${"--nth " + cpu}
	}
	output {
		File plot = glob("*.cc.plot.pdf")[0]
		File score = glob("*.cc.qc")[0]
	}
	runtime {
		cpu : "${select_first([cpu,1])}"
		queue : queue
	}
}

task macs2 {
	# parameters from workflow
	File ta
	String gensz		# Genome size (sum of entries in 2nd column of 
                        # chr. sizes file, or hs for human, ms for mouse)
	File chrsz			# 2-col chromosome sizes file
	Int? cap_num_peak	# cap number of raw peaks called from MACS2
	Float? pval_thresh	# p.value threshold
	Int? smooth_win		# size of smoothing window
	Boolean? make_signal
	# resource
	Int? mem_mb
	Int? time_hr
	String? queue

	command {
		python $(which encode_dcc_macs2.py) \
			${ta} \
			${"--gensz "+ gensz} \
			${"--chrsz " + chrsz} \
			${"--cap-num-peak " + cap_num_peak} \
			${"--p-val-thresh "+ pval_thresh} \
			${"--smooth-win "+ smooth_win} \
			${if select_first([make_signal,false])
				then "--make-signal" else ""}
	}
	output {
		File npeak = glob("*.narrowPeak.gz")[0]
		# optional (generated only if make_signal)
		Array[File] sig_pval = glob("*.pval.signal.bigwig")
		Array[File] sig_fc = glob("*.fc.signal.bigwig")
	}
	runtime {
		memory : "${select_first([mem_mb,'100'])} MB"
		time : "${select_first([time_hr,1])}"
		queue : queue
	}
}

task idr {
	# parameters from workflow
	String? prefix 		# prefix for IDR output file
	File peak1 			
	File peak2
	File peak_pooled
	Float? idr_thresh
	# resource
	String? queue

	command {
		python $(which encode_dcc_idr.py) \
			${peak1} ${peak2} ${peak_pooled} \
			${"--prefix " + prefix} \
			${"--idr-thresh " + idr_thresh} \
			--idr-rank signal.value
	}
	output {
		File idr_peak = glob("*peak.gz")[0]
		File idr_plot = glob("*.txt.png")[0]
		File idr_unthresholded_peak = glob("*.txt.gz")[0]
		File idr_log = glob("*.log")[0]
	}
	runtime {
		queue : queue
	}
}

task overlap {
	# parameters from workflow
	String? prefix 		# prefix for IDR output file
	File peak1
	File peak2
	File peak_pooled
	# resource
	String? queue

	command {
		python $(which encode_dcc_naive_overlap.py) \
			${peak1} ${peak2} ${peak_pooled} \
			${"--prefix " + prefix}
	}
	output {
		File overlap_peak = glob("*peak.gz")[0]
	}
	runtime {
		queue : queue
	}
}

task reproducibility {
	# parameters from workflow
	Array[File]? peaks 	# peak files from pair of true replicates
						# in a sorted order. for example of 4 replicates,
						# 1,2 1,3 1,4 2,3 2,4 3,4.
                        # x,y means peak file from rep-x vs rep-y
	Array[File] peaks_pr	# peak files from pseudo replicates
	File? peak_ppr			# Peak file from pooled pseudo replicate.
	# resource
	String? queue

	command {
		python $(which encode_dcc_reproducibility_qc.py) \			
			${sep=' ' peaks} \
			--peaks-pr ${sep=' ' peaks_pr} \
			${"--peak-ppr "+ peak_ppr}
	}
	output {
		File reproducibility_qc = 
			glob("*.reproducibility.qc")[0]
	}
	runtime {
		queue : queue
	}
}

task blacklist_filter {
	# parameters from workflow
	File peak
	File blacklist
	# resource
	String? queue

	command {
		python $(which encode_dcc_blacklist_filter.py) \
			${peak} \
			${blacklist}
	}
	output {
		File filtered_peak = glob('*.gz')[0]
	}
	runtime {
		queue : queue
	}
}

task frip {
	# parameters from workflow
	File peak
	File ta
	# resource
	String? queue

	command {
		python $(which encode_dcc_frip.py) \
			${peak} \
			${ta}
	}
	output {
		File frip_qc = glob('*.frip.qc')[0]
	}
	runtime {
		queue : queue
	}
}

# workflow system tasks
task inputs {	# determine input type and number of replicates	
	# parameters from workflow
	Array[Array[Array[String]]] fastqs 
	Array[String] bams
	Array[String] nodup_bams
	Array[String] tas

	command <<<
		python <<CODE
		name = ['fastq','bam','nodup_bam','ta']
		arr = [${length(fastqs)},${length(bams)},
		       ${length(nodup_bams)},${length(tas)}]
		num_rep = max(arr)
		type = name[arr.index(num_rep)]
		with open('num_rep.txt','w') as fp:
		    fp.write(str(num_rep)) 
		with open('type.txt','w') as fp:
		    fp.write(type)		    
		CODE
	>>>
	output {
		String type = read_string("type.txt")
		Int num_rep = read_int("num_rep.txt")
	}
}

task pair_gen { # returns every pair of true replicate
	Int num_rep
	command <<<
		python <<CODE
		for i in range(${num_rep}):
		    for j in range(i+1,${num_rep}):
		        print('{}\t{}'.format(i,j))
		CODE
	>>>
	output {
		Array[Array[Int]] pairs = read_tsv(stdout())
	}
}