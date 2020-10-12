version 1.0

# Currently assumes only one bam is the input

task index {
	input {
		File inputBamOrCram
		String outputIndexString
	}

	command {
		samtools index ${inputBamOrCram} ${outputIndexString}
	}

	output {
		File outputIndex = outputIndexString
	}

	runtime {
        docker: "quay.io/biocontainers/goleft:0.2.0--0"
    }
}

task getReadLengthAndCoverage {
	input {
		File inputBamOrCram
		File? inputIndex # if samtools index was called
		Array[File] allInputIndexes # if samtools index was not called
		File? refGenome
		Float? thisCoverage # might be removable
		Int? thisReadLength # might be removable
	}

	command <<<

		#if defined(refGenome)

		# For some reason, a panic in go doesn't exit with status 1, so we
		# have to catch file not found exceptions ourselves
		if [ -f ~{inputBamOrCram} ]; then
			echo "Input bam file exists"
		else 
			>&2 echo "Input bam file (~{inputBamOrCram}) not found, panic"
			exit 1
		fi
		
		# If the user passes in the indeces, they will be in the same input folder
		# as the input bams and crams. If samtools index was called to generate the
		# indeces, then they will be in a different folder, hence the need for two
		# checks. Unfortunately neither cover the "user defined an input that is like
		# foo.bai instead of foo.bam.bai" so for now failing both does not exit 1

		if [ -f ~{inputBamOrCram}.bai ]; then
			# User-defined input exists
			echo "Input bai file exists, likely passed in by user"
		else
			if [ -f ~{inputIndex} ]; then
				# samtools index's output exists
				echo "Input bai file exists, likely output of samtools index"
			else
				>&2 echo "Cursory search for the index file failed. Task may still succeed."
				#echo "~{inputBamOrCram}" | sed 's/\.[^.]*$//'
				#otherPossibility=$("~{inputBamOrCram}" | sed 's/\.[^.]*$//')
				#if [-f ${otherPossibility}.bai]; then
					#echo "Input has been found"
				#else
					#>&2 echo "Input bai file (~{inputBamOrCram}.bai) nor ${otherPossibility}.bai not found, panic"
					#exit 1
				#fi
			fi
		fi

		# goleft tries to look for the bai in the same folder as the bam, but 
		# they're never in the same folder when run via Cromwell, so we have
		# to symlink it. goleft automatically checks for both name.bam.bai and
		# name.bai so it's okay if we use either 
		inputBamDir=$(dirname ~{inputBamOrCram})
		ln -s ~{inputIndex} ~{inputBamOrCram}.bai
		
		goleft covstats ~{inputBamOrCram} >> this.txt
		COVOUT=$(tail -n +2 this.txt)
		read -a COVARRAY <<< "$COVOUT"
		echo ${COVARRAY[1]} > thisCoverage
		echo ${COVARRAY[11]} > thisReadLength
		BASHFILENAME=$(basename ~{inputBamOrCram})
		echo "'${BASHFILENAME}'" > thisFilename

	>>>
	output {
		Int outReadLength = read_int("thisReadLength")
		Float outCoverage = read_float("thisCoverage")
		String outFilenames = read_string("thisFilename")
	}
	runtime {
        docker: "quay.io/biocontainers/goleft:0.2.0--0"
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

	pyReadLengths = ~{sep="," readLengths} # array of ints
	pyCoverages = ~{sep="," coverages} # array of floats
	pyFilenames = ~{sep="," filenames} # array of strings, hopefully
	i = 0

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
}

workflow covstats {
	input {
		Array[File] inputBamsOrCrams
		Array[File]? inputIndexes
		File? refGenome # required if using crams... if crams can work at all
	}

	# weird workaround to see if inputIndexes are defined
	Array[String] wholeLottaNada = []
	Array[String] allIndexes = select_first([inputIndexes, wholeLottaNada])

	scatter(oneBamOrCram in inputBamsOrCrams) {
		Array[File] batchInputAms = [oneBamOrCram]
		String outputBaiString = "${basename(oneBamOrCram)}.bai"
		
		# scattered
		if (length(allIndexes) != length(inputBamsOrCrams)) {
			# Some possible snags
			# (1) Neither bam/crams nor indeces defined
			# (2) Same number of files in each array but they don't
			#     line up, ie ["foo.bam"] and ["bar.bai"]
			# (3) Same number of files with correct names but the
			#     index files are wrong, ie foo.bai does not
			#     actually represent foo.bam
			# 1 isn't really an issue as it will error out almost
			# immediately.
			# 2 will print to stderr but the last error will be
			# an unhelpful magic number error in go
			# 3 will cause a silent go panic for index being out of
			# range but won't error until every bam/cram has been
			# processed and that reported error on the cli will be
			# bad output
			call index { 
				input:
					inputBamOrCram = oneBamOrCram,
					outputIndexString = outputBaiString
			}
		}

		#scattered
		call getReadLengthAndCoverage as scatteredGetStats { 
			input:
				inputBamOrCram = oneBamOrCram,
				refGenome = refGenome,
				# Let me explain this foolishness...
				# samtools index takes time so we want to skip it whenever
				# possible. If the user does not supply indexes for every
				# input (technically it's if the user's bam/cram inputs is
				# a different number of files then the user's bai/crai inputs)
				# then a scattered samtools index will run. That scattered
				# samtools index will return a single index file, which
				# is index.outputIndex. But if the user does define indeces,
				# then the index will be some file in the input array. Iterating
				# arrays in WDl is a nightmare, as well as unnecessary in this
				# situation, because the index just needs to be in the working
				# directory when covstats is run. So whether we pass in an
				# array of files or just a single file, we're good. The problem
				# is we can't use another if (or the same if as above) to just
				# say "if user defined indeces then pass in the array else pass
				# in the output of samtools index" because Cromwell does not
				# recognize those two ifs (WDL lacks an else statement) as being
				# mutually exclusive, so it's mad that results are being duplicated.
				# So we try to pass in both a file AND an array, both of which are
				# optional inputs. Recall that allIndexes is already the result
				# of a select_first(), so it is either the users' passed in index
				# files, or an empty array. An empty array is still a valid array
				# in WDL so that's fine and dandy. But, if you pass an empty string
				# or a file that doesn't exist into a File or File? input, that is
				# not valid. One possible workaround would be to create an extra task
				# that simply just uses bash touch to create a blank file, but when
				# running locally even quick tasks slow down execution. So it's more
				# efficient to use some other file as the dummy file that will be
				# passed in when the user does define indeces and samtools index is
				# skipped. So what's a file that always will be defined, without
				# fail? The exact same bam or cram file we are running covstats on.
				allInputIndexes = allIndexes,
				inputIndex = select_first([index.outputIndex, oneBamOrCram])
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