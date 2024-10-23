~slice_input_by_onset = {

	|in_buf, indices_buf|

	FluidBufOnsetSlice.processBlocking(s,in_buf,indices:indices_buf,metric:0,threshold:0.5,minSliceLength:60,action:{ // do the slicing
		indices_buf.loadToFloatArray(action:{
			arg indices_array;

			// post the results so that you can tweak the parameters and get what you want
			"found % slices".format(indices_array.size-1).postln;
			"average length: % seconds".format((in_buf.duration / (indices_array.size-1)).round(0.001)).postln;
		})
	});
};

~slice_input_by_novelty = {

	|in_buf, indices_buf, feature=1|

	FluidBufNoveltySlice.processBlocking(
		s,
		in_buf,
		indices:indices_buf,
		algorithm:feature,
		kernelSize:5,
		threshold:0.5,
		minSliceLength:10,action:{ // do the slicing
			indices_buf.loadToFloatArray(action:{
				arg indices_array;

				// post the results so that you can tweak the parameters and get what you want
				"found % slices".format(indices_array.size-1).postln;
				"average length: % seconds".format((in_buf.duration / (indices_array.size-1)).round(0.001)).postln;
			})
	});
};

// pretty sure Ted Moore wrote some of this code, thanks Ted

~analyze_to_dataset = {
	arg audio_buffer, slices_buffer, action; // the audio buffer to analyze, a buffer with the slice points, and an action to execute when done
	var features_buf = Buffer(s); // a buffer for writing the MFCC analyses into
	var stats_buf = Buffer(s);  // a buffer for writing the statistical summary of the MFCC analyses into
	var flat_buf = Buffer(s); // a buffer for writing only he mean MFCC values into
	var dataset = FluidDataSet(s); // the dataset that all of these analyses will be stored in
	~nmfccs = 13;


	slices_buffer.loadToFloatArray(action:{ // get the indices from the server loaded down to the language
		arg slices_array;
		fork{
			// iterate over each index in this array, paired with this next neighbor so that we know where to start
			// and stop the analysis
			slices_array.doAdjacentPairs{
				arg start_frame, end_frame, slice_index;
				var num_frames = end_frame - start_frame;

				"analyzing slice: % / %".format(slice_index + 1,slices_array.size - 1).postln;

				// mfcc analysis, hop over that 0th coefficient because it relates to loudness and here we want to focus on timbre
				FluidBufMFCC.processBlocking(s,audio_buffer,start_frame,num_frames,features:features_buf,startCoeff:1,numCoeffs:~nmfccs);
				// FluidBufSpectralShape.processBlocking(s,audio_buffer,start_frame,num_frames,features:features_buf,numChans:1, select:[\centroid]);
				// FluidBufChroma.processBlocking(s,audio_buffer,start_frame,num_frames,features:features_buf,numChans:1);

				// get a statistical summary of the MFCC analysis for this slice
				FluidBufStats.processBlocking(s,features_buf,stats:stats_buf,select:[\mean]);

				// extract and flatten just the 0th frame (numFrames:1) of the statistical summary (because that is the mean)
				FluidBufFlatten.processBlocking(s,stats_buf,destination:flat_buf);

				// now that the means are extracted and flattened, we can add this datapoint to the dataset:
				dataset.addPoint("slice-%".format(slice_index),flat_buf);

				if((slice_index % 100) == 99){s.sync};
			};

			s.sync;

			action.value(dataset); // execute the function and pass in the dataset that was created!
		};
	});
};

~play_source_index = {
	arg index, source_buf, source_indices_buf, pan, src_dur = 1;
	{
		var start_frame = Index.kr(source_indices_buf,index); // lookup the start frame with the index *one the server* using Index.kr
		var end_frame = Index.kr(source_indices_buf,index+1); // same for the end frame
		var num_frames = end_frame - start_frame;
		var dur_secs = min(num_frames / SampleRate.ir(source_buf),src_dur);
		var sig = BRF.ar(HPF.ar(PlayBuf.ar(1,source_buf,BufRateScale.ir(source_buf),0,start_frame,0,2, 110)));
		var env = EnvGen.kr(Env([0,1,1,0],[0.05,dur_secs-0.1,0.05]),doneAction:2);


		sig = sig * env; // include this env if you like, but keep the line above because it will free the synth after the slice!

		sig = Limiter.ar(Pan2.ar(sig, pan), 0.95);

		Out.ar([2, 3],sig);

		nil;
	}.play;
};

