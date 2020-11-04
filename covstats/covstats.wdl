version 1.0

task getReadLengthAndCoverage {
	input {
		File inputBamOrCram
		Array[File] allInputIndexes
		File? refGenome
		String toUse
	}

	command <<<

		start=$SECONDS

		set -eux -o pipefail

		if [ -f ~{inputBamOrCram} ]; then
				echo "Input bam or cram file exists"
		else 
				>&2 echo "Input bam or cram file (~{inputBamOrCram}) not found, panic"
				exit 1
		fi

		AMIACRAM=$(echo ~{inputBamOrCram} | sed 's/\.[^.]*$//')

		if [ -f ${AMIACRAM}.cram ]; then
			echo "Cram file detected"
			if [ "~{refGenome}" != '' ]; then
				goleft covstats -f ~{refGenome} ~{inputBamOrCram} >> this.txt
				# Sometimes this.txt seems to be missing the header... investigate
				COVOUT=$(tail -n +2 this.txt)
				read -a COVARRAY <<< "$COVOUT"
				echo ${COVARRAY[0]} > thisCoverage
				echo ${COVARRAY[11]} > thisReadLength
				BASHFILENAME=$(basename ~{inputBamOrCram})
				echo "'${BASHFILENAME}'" > thisFilename
			else
				# Cram file but no reference genome
				>&2 echo "Cram detected but cannot find reference genome."
				>&2 echo "A reference genome is required for cram inputs."
				exit 1
			fi
		
		else
			# Bam file

			OTHERPOSSIBILITY=$(echo ~{inputBamOrCram} | sed 's/\.[^.]*$//')

			if [ -f ~{inputBamOrCram}.bai ]; then
				# foo.bam.bai
				echo "Bai file already exists with pattern *.bam.bai"
			elif [ -f ${OTHERPOSSIBILITY}.bai ]; then
				# foo.bai
				echo "Bai file already exists with pattern *.bai"
			else
				echo -n "Input bai file (~{inputBamOrCram}.bai)"
				echo " nor ${OTHERPOSSIBILITY}.bai not found"
				samtools index ~{inputBamOrCram} ~{inputBamOrCram}.bai
			fi
			
			goleft covstats -f ~{refGenome} ~{inputBamOrCram} >> this.txt

			COVOUT=$(tail -n +2 this.txt)
			read -a COVARRAY <<< "$COVOUT"
			echo ${COVARRAY[0]} > thisCoverage
			echo ${COVARRAY[11]} > thisReadLength
			BASHFILENAME=$(basename ~{inputBamOrCram})
			echo "'${BASHFILENAME}'" > thisFilename
		fi

		duration=$(( SECONDS - start ))
		echo ${duration} > duration

	>>>

	# Estimate disk size required
	Int refSize = ceil(size(refGenome, "GB"))
	Int indexSize = ceil(size(allInputIndexes, "GB"))
	#lets see if we can do this on a task level to save space
	#Int amSize = ceil(size(inputBamsOrCrams, "GB"))
	Int thisAmSize = ceil(size(inputBamOrCram, "GB"))

	# If input is a cram, it will get samtools'ed into a bam,
	# so we need to at least double its size for the disk
	# calculation. Eventually we might be be able to go back
	# to the old mess of the cram-support branch (PR3) at least
	# in terms of determining if something is a cram ahead of time
	# in order to maximize savings.

	Int finalDiskSize = refSize + indexSize + (2*thisAmSize)

	output {
		Int outReadLength = read_int("thisReadLength")
		Float outCoverage = read_float("thisCoverage")
		String outFilenames = read_string("thisFilename")
		Int duration = read_int("duration")
	}
	runtime {
		docker: if toUse == "true" then "quay.io/biocontainers/goleft:0.2.0--0" else "quay.io/aofarrel/goleft-covstats:custom-docker"
		preemptible: 1
		disks: "local-disk " + finalDiskSize + " HDD"
	}
}

task report {
	input {
		Array[Int] readLengths
		Array[Float] coverages
		Array[String] filenames
		Int lenReads = length(readLengths)
		Int lenCov = length(coverages)
	}

	command <<<
	python << CODE

	f = open("reports.txt", "a")

	pyReadLengths = ~{sep="," readLengths} # array of ints OR int
	pyCoverages = ~{sep="," coverages} # array of floats OR float
	pyFilenames = ~{sep="," filenames} # array of strings OR string
	i = 0

	# if there was just one input, the above will not be arrays
	if (type(pyReadLengths) == int):
		f.write("Filename\tRead length\tCoverage\n")
		f.write("{}\t{}\t{}\n".format(pyFilenames, pyReadLengths, pyCoverages))
		f.close()
	else:
		# print "table" with each inputs' read length and coverage
		f.write("Filename\tRead length\tCoverage\n")
		while i < len(pyReadLengths):
			f.write("{}\t{}\t{}\n".format(pyFilenames[i], pyReadLengths[i], pyCoverages[i]))
			i += 1
		# print average read length
		avgRL = sum(pyReadLengths) / ~{lenReads}
		f.write("Average read length: {}\n".format(avgRL))
		avgCv = sum(pyCoverages) / ~{lenCov}
		f.write("Average coverage: {}\n".format(avgCv))
		f.close()

	CODE
	>>>

	output {
		File finalOut = "reports.txt"
	}

	runtime {
		docker: "python:3.8-slim"
		preemptible: 2
	}
}

task debugEchoes1 {
	# I regret this, but my hand has been forced.
	input {
		String toEcho
	}

	command <<<
	echo ~{toEcho} > debugInformation.txt
	>>>

	output {
		String debugInformation = read_string("debugInformation.txt")
	}

	runtime {
		docker: "python:3.8-slim"
		preemptible: 1
	}
}

task debugEchoes2 {
	# I regret this, but my hand has been forced.
	input {
		String toEcho
	}

	command <<<
	echo ~{toEcho} > debugInformation.txt
	>>>

	output {
		String debugInformation = read_string("debugInformation.txt")
	}

	runtime {
		docker: "python:3.8-slim"
		preemptible: 1
	}
}

workflow covstats {
	input {
		Array[File] inputBamsOrCrams
		Array[File]? inputIndexes
		File? refGenome
		String? useLegacyContainer
	}

	# weird workaround to see if inputIndexes are defined, used in old
	# versions but now more of an error fallback
	Array[String] wholeLottaNada = []

	# Figure out which Docker to use
	String toUse = select_first([useLegacyContainer, "false"])

	# It appears this cannot be done on the task level as if statements
	# outside the command syntax of a task upset womtool, but at the same
	# time we cannot put tasks themselves in if statements because womtool
	# does not recognize they are mutually exclusive and gets upset about
	# the possibility of duplicated results.
	# Likewise it seems they cannot go in the workflow section as it cannot
	# tell when multiple if statements are mutually exclusive.
	# 

	if (toUse == "true") {
		call debugEchoes1 {input: toEcho = "Using legacy Docker container"}
	}

	if (toUse == "false") {
		call debugEchoes2 {input: toEcho = "Using updated Docker container"}
	}

	# Catching input typos from user doesn't seem possible due to how variables 
	# are scoped unfortunately, but I did make an attempt which I stored here
	# https://gist.github.com/aofarrel/ef71e1a27d824cbcc8acb11b6abe6e19
	# in case some brave soul wants to take a crack at it


	# call covstats
	scatter(oneBamOrCram in inputBamsOrCrams) {
		Array[String] allOrNoIndexes = select_first([inputIndexes, wholeLottaNada])
		
		call getReadLengthAndCoverage as scatteredGetStats { 
			input:
				inputBamOrCram = oneBamOrCram,
				refGenome = refGenome,
				allInputIndexes = allOrNoIndexes,
				toUse = toUse
		}
	}

	# not scattered
	call report {
		input:
			readLengths = scatteredGetStats.outReadLength,
			coverages = scatteredGetStats.outCoverage,
			filenames = scatteredGetStats.outFilenames
	}

	meta {
		author: "Ash O'Farrell"
		email: "aofarrel@ucsc.edu"
    }
}
