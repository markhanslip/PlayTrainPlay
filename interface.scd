(
s.quit;
s.options.device = "ZEDi10";
s.options.memSize = 8192*32;
s.options.numBuffers = 1028*32;
s.options.blockSize = 512;
s.options.hardwareBufferSize = 512;
s.options.sampleRate = 48000;
s.options.numInputBusChannels = 1;
s.options.numOutputBusChannels = 4;
s.recSampleFormat = "float";
s.recHeaderFormat = "wav";
s.waitForBoot({

	SynthDef(\recorder, {

		|bufnum = 0|

		RecordBuf.ar(
			SoundIn.ar(0),
			bufnum, loop:0, trigger:1, doneAction:2);
	}).add;

	SynthDef(\var_len_recorder, {

		|rec_buf = 0, gate = 1|

		var trig_gate = 1-gate;
		// the signal to be recorded
		var input = SoundIn.ar(0); // change to bus 1 if going through effects rig first
		// send time used for recording back to language
		SendTrig.kr(trig_gate, 0, Line.kr(0, 480000, 480000));
		// release synth when recGate closes
		FreeSelf.kr(trig_gate);

		RecordBuf.ar(input, rec_buf, doneAction:2);

	}).add;


	fork { case { MIDIClient.initialized.not } { MIDIClient.init; MIDIIn.connectAll; } };

	"/Users/m4rk/Documents/NIME/implementation/Sep_update/kdtree_funcs.scd".loadPaths; // grab helper funcs
	2.0.wait;
	s.sync;

	~section_counter = 0;
	~var_len_rec_counter = 0;
	~solo_buffer = nil;
	~is_looping = 0;
	~is_concating = 0;
	~novelty_thresh = 0.4; // changes sensitivity of k-d tree concat synth
	~kernel_size = 7; // changes sensitivity of k-d tree concat synth (odd number)
	~stutter = [3, 4, 5, 6, 7, 8, 9, 10, 11, 12];
	~stutter_overlap = [1.25];

	~inferences_per_sec = 0.5;

	~delay_buffer = Buffer.alloc(s, s.sampleRate*0.5);

	// dataset globals

	~input_buffer = Buffer.alloc(s,12); // for MFCC coeffs
	~output_buffer = Buffer.alloc(s,3); // for grain params (overlap, trig speed, pitch shift)

	~in_data = FluidDataSet(s);
	~out_data = FluidDataSet(s);
	~entry_counter = 0;

	~indices_buf = Buffer(s);

	// nn architecture

	~mlp = FluidMLPRegressor(
		s, [12],
		activation:1, outputActivation:0,
		maxIter: 1000, learnRate: 0.01,
		momentum: 0.9, batchSize: 1,
		validation:0
	);

	// training function

	~continuous_train = true;
	~train = {
		~mlp.fit(~in_data_scaled,~out_data,{
			arg loss;
			("loss: " ++ loss).postln;
			if(~continuous_train,{
				~train.();
			});
		})
	};

	~is_training = 0;
	~is_tree = 0;

	s.sync;

	Ndef(\grain_effect, {

		| rate = 0, trig_freq = 10, ptr_del = 0.2, overlap = 1 |

		var input, pointer, max_grain_dur, output, grain_env, env_buf, trig;

		grain_env = Env([0, 0.9, 0], [0.5, 0.01], 'cub'); // lin ?
		env_buf = Buffer.sendCollection(s, grain_env.discretize(8192));

		trig = Impulse.kr(trig_freq);

		input =	Compander.ar(
			in:SoundIn.ar(0),
			control:SoundIn.ar(0),
			thresh:0.005,
			slopeBelow:10,
			slopeAbove:1,
			clampTime:0.01,
			relaxTime:0.05
		);

		pointer = Phasor.ar(
			trig:0,
			rate:BufRateScale.ir(~delay_buffer),
			start:0,
			end:BufFrames.ir(~delay_buffer)
		);

		BufWr.ar(input, ~delay_buffer, pointer);

		output =  GrainBuf.ar(
			numChannels:1,
			trigger:trig,
			dur: overlap / trig_freq,
			sndbuf: ~delay_buffer,
			// rate:TChoose.kr(trig, [1, rate.midiratio, (0-rate).midiratio]),
			rate:rate.midiratio,
			pos: (pointer - (ptr_del * SampleRate.ir)) / BufFrames.ir(~delay_buffer),
			envbufnum:env_buf
		);

		output;

	}).play([0, 1]);

	// Ndef(\grain_regression_player).fadeTime = 0.25;

	Ndef(\grain_effect).fadeTime = 0.1;

	Ndef(\get_MFCCs, {

		var in = SoundIn.ar(0);
		var mfccs = FluidMFCC.kr(in, 13, minFreq:40, maxFreq:2000);

		SendReply.ar(Impulse.ar(1), '/log_MFCCs', mfccs);
	});

	// grain synth globals

	~overlap = 1;
	~trig_speed = 4;
	~grain_shift = 0;

	Ndef(\grain_effect).set(\overlap, ~overlap, \trig_freq, ~trig_speed, \rate, ~grain_shift);

	s.sync;

	MIDIdef.cc(\bluetooth_footswitch, {

		|...msgs|

		case

		{msgs[0] == 12 && msgs[1] == 3} {~section_counter = ~section_counter+1;

			// define pedal modes

			case

			{~section_counter == 1} {

				''.postln;
				'************************'.postln;
				'************************'.postln;
				'*******   play   *******'.postln;
				'************************'.postln;
				'************************'.postln;
				''.postln;
				//"grain effect improv, data logging via footswitch".postln;
			}

			{~section_counter == 2} {

				''.postln;
				'************************'.postln;
				'************************'.postln;
				'*******  train   *******'.postln;
				'************************'.postln;
				'************************'.postln;
				''.postln;
				// "training the model, stutter effect on last sound".postln;
			}

			{~section_counter == 3} {

				''.postln;
				'************************'.postln;
				'************************'.postln;
				'*******   play   *******'.postln;
				'************************'.postln;
				'************************'.postln;
				''.postln;				// "interaction with the trained model".postln;
			}

			{~section_counter >= 4} {~section_counter = 0; "reset mode counter".postln;}
		}

		// TO DO: ADD ANOTHER ONE OF THESE FOR PITCH SHIFT (2nd EXP PEDAL)

		{~section_counter == 1 && msgs[1] == 6} {

			~trig_speed = msgs[0].linlin(0, 127, 5, 12);
			~overlap = msgs[0].linlin(0, 127, 1.1, 2.0);
			// ~grain_shift = msgs[0].linlin(0, 127, 0, 5).asInteger;

			("density: " ++ ~trig_speed.asString ++ " grains per sec").postln;
			("grain overlap: " ++ ~overlap.asString).postln;
			// ("random shift: " ++ (~grain_shift.asInteger).asString ++ " semitones").postln;
			Ndef(\grain_effect).set(\trig_freq, ~trig_speed, \overlap);
		}

		{~section_counter == 1 && msgs[1] == 5} {

			~grain_shift = msgs[0].linlin(0, 127, 0, 7).asInteger;
			("detune: " ++ (~grain_shift.asInteger).asString ++ " semitones").postln;
			Ndef(\grain_effect).set(\rate, 0 - ~grain_shift);
		}

		{~section_counter == 1 && msgs[0] == 10 && msgs[1] == 1} {

			~var_len_rec_counter = ~var_len_rec_counter + 1;

			case

			{~var_len_rec_counter == 1} {

				{

					~max_len = 60 * 10; // this should be plenty
					~init_buf = Buffer.alloc(s, (~max_len * s.sampleRate), 1);
					~var_len_recorder = Synth.new(\var_len_recorder, [\rec_buf, ~init_buf.bufnum]);
					0.1.wait;

					'recording'.postln;

					OSCdef(\rec_len, { // copies the recording into a new variable-length buffer

						|msg, time|

						~rec_len = msg[3];
						~rec_len_frames = (~rec_len * s.sampleRate).trunc;
						~solo_buffer = Buffer.alloc(s, ~rec_len_frames, 1, {

							|buf|

							~init_buf.copyMsg(buf, 0, 0, ~rec_len_frames);
						});

					}, '/tr');

				}.fork;
			}

			{~var_len_rec_counter == 2} {

				{
					~var_len_recorder.set(\gate, 0); 'stopped recording'.postln;
					0.1.wait;
					s.sync;

					~var_len_rec_counter = 0;

				}.fork;
			}
		}

		{~section_counter == 1 && msgs[0] == 13 && msgs[1] == 4} {

			fork{

				~mfccs = [];
				~durs = [];
				~trigs = [];

				// grab MFCCs from live input

				// log them to the input dataset and the current params to the output dataset

				OSCdef(\log_MFCCs, {

					|msg|

					~mfccs = ~mfccs.add([msg[4..16]]);

				}, '/log_MFCCs');

				1.wait;

				~mfccs = ~mfccs.flatten;
				~mfccs = ~mfccs.flatten;
				~grain_params = [~overlap, ~trig_speed, ~grain_shift];

				~input_buffer.setn(0, ~mfccs);
				~output_buffer.setn(0, ~grain_params);

				~in_data.addPoint(~entry_counter.asSymbol, ~input_buffer);
				~out_data.addPoint(~entry_counter.asSymbol, ~output_buffer);

				~entry_counter = ~entry_counter + 1;

				''.postln;
				'logged effect params to dataset:'.postln; // this can be formatted nicely later
				''.postln;

				~in_data.print;
				~out_data.print;
			};
		}

		{~section_counter == 2 && msgs[0] == 10 && msgs[1] == 1} {

			~is_training = ~is_training + 1;

			case

			{ ~is_training == 1 } {

				fork{

					// record the input and stutter it so something sonic is happening while the models train:

					~train_buf = Buffer.alloc(s, numFrames:(s.sampleRate/4).asInteger, numChannels:1);

					Synth.new(\recorder, [\out, 0, \bufnum, ~train_buf]);

					"recording granular buffer".postln;

					(~train_buf.duration + 0.1).wait;

					Ndef(\grain_effect, {

						var grain_env = Env([0, 0.9, 0], [0.5, 0.01], 'cub'); // lin ?
						var env_buf = Buffer.sendCollection(s, grain_env.discretize(8192));

						var trig = Dust.kr(0.6);

						var trig_freq = TChoose.kr(trig, ~stutter);

						var overlap = TChoose.kr(trig, ~stutter_overlap);

						var stutter = GrainBuf.ar(
							numChannels:1,
							trigger:Impulse.ar(trig_freq),
							dur:(overlap/trig_freq),
							sndbuf:~train_buf,
							// pos:0.1
							pos:TChoose.kr(trig, [0.1, 0.2, 0.3, 0.4]),
							envbufnum:env_buf,
							rate: (0 - (~grain_shift.midiratio))
						);

						(stutter!2) * 0.65;

					}).play([0, 1]);

					// first we normalize the data

					'normalizing the input data'.postln;

					~mfcc_scaler = FluidNormalize(s);
					~in_data_scaled = FluidDataSet(s);
					~mfcc_scaler.fitTransform(~in_data,~in_data_scaled);

					'scaled input data: '.postln;
					~in_data_scaled.print;
					'output data: '.postln;
					~out_data.print;

					// bear in mind that it might be easier to use the pre-transform x y data as target as is scaled to 0, 1, in which case set globals for those

					1.0.wait;

					// train that model

					''.postln;
					'**************************'.postln;
					'**************************'.postln;
					'***  training the mlp  ***'.postln;
					'**************************'.postln;
					'**************************'.postln;
					''.postln;

					~train.();
				}
			}

			{~is_training == 2} {
				~continuous_train = false;
				"stopped training, model ready to use".postln;
				~is_training = 0;
			}
		}

		{~section_counter == 2 && msgs[0] == 11 && msgs[1] == 2} {

			~is_tree = ~is_tree + 1;

			case

			{ ~is_tree == 1 } {

				// IDK why yet but sometimes this only works the second time:

				''.postln;
				'**************************************'.postln;
				'**************************************'.postln;
				'** slicing and analysing first solo **'.postln;
				'**************************************'.postln;
				'**************************************'.postln;
				''.postln;

				FluidBufNoveltySlice.processBlocking(
					s,
					~solo_buffer,
					indices:~indices_buf,
					algorithm:1,
					kernelSize:7,
					threshold:0.25,
					minSliceLength:10, action:{ // do the slicing
						~indices_buf.loadToFloatArray(action:{
							arg indices_array;

							// post the results so that you can tweak the parameters and get what you want
							"found % slices".format(indices_array.size-1).postln;
							"average length: % seconds".format((~solo_buffer.duration / (indices_array.size-1)).round(0.001)).postln;
						})
				});

				~analyze_to_dataset.(~solo_buffer, ~indices_buf,{ // pass in the audio buffer of the source, and the slice points
					arg ds;
					~source_dataset = ds; // set the ds to a global variable so we can access it later
					~source_dataset.print;
				});
			}

			{ ~is_tree == 2 } {

				''.postln;
				'**************************'.postln;
				'**************************'.postln;
				'***  fitting the tree  ***'.postln;
				'**************************'.postln;
				'**************************'.postln;
				''.postln;

				~kdtree = FluidKDTree(s);
				~scaled_dataset = FluidDataSet(s);

				// ~scaler = FluidStandardize(s);
				~scaler = FluidNormalize(s);
				// ~scaler = FluidRobustScale(s);

				~scaler.fitTransform(~source_dataset,~scaled_dataset);
				~kdtree.fit(~scaled_dataset,{"tree has been fit".postln;});

				~mfccbuf = Buffer.alloc(s,13);
				~scaledbuf = Buffer.alloc(s,13);
				~is_tree = 0;
			}

		}

		{~section_counter == 3 && msgs[0] == 10 && msgs[1] == 1} { ~is_looping = ~is_looping + 1;

			case

			{~is_looping == 1} {

				// final interactive section

				''.postln;
				'******************************************'.postln;
				'******************************************'.postln;
				'***  interacting with the trained mlp  ***'.postln;
				'******************************************'.postln;
				'******************************************'.postln;
				''.postln;

				// Ndef(\stutter).free(2);

				Ndef(\grain_effect, {

					| rate = 0, trig_freq = 10, ptr_del = 0.2, overlap = 1 |

					var input, pointer, max_grain_dur, output, grain_env, env_buf, trig;

					grain_env = Env([0, 0.9, 0], [0.5, 0.01], 'cub'); // lin ?
					env_buf = Buffer.sendCollection(s, grain_env.discretize(8192));

					trig = Impulse.kr(trig_freq);

					input =	Compander.ar(
						in:SoundIn.ar(0),
						control:SoundIn.ar(0),
						thresh:0.005,
						slopeBelow:10,
						slopeAbove:1,
						clampTime:0.01,
						relaxTime:0.05
					);

					pointer = Phasor.ar(
						trig:0,
						rate:BufRateScale.ir(~delay_buffer),
						start:0,
						end:BufFrames.ir(~delay_buffer)
					);

					BufWr.ar(input, ~delay_buffer, pointer);

					output =  GrainBuf.ar(
						numChannels:1,
						trigger:trig,
						dur: overlap / trig_freq,
						sndbuf: ~delay_buffer,
						// rate:TChoose.kr(trig, [1, rate.midiratio, (0-rate).midiratio]),
						rate:rate.midiratio,
						pos: (pointer - (ptr_del * SampleRate.ir)) / BufFrames.ir(~delay_buffer),
						envbufnum:env_buf
					);

					output;

				}).play([0, 1]);

				Ndef(\send_mfccs, {

					var values = FluidMFCC.kr(
						in:SoundIn.ar(0),
						numCoeffs:13,
						startCoeff:0,
						minFreq:40,
						maxFreq:2000
					);

					var trig = Impulse.kr(0.5);

					SendReply.kr(trig:trig, cmdName:'/mfccs', values:values);
				});

				OSCdef(\set_params, {

					|msg|

					~mfcc_array = msg[3..][1..];

					fork{

						~mfcc_output_buf = Buffer.alloc(s, 12);
						~mfcc_output_buf.loadCollection(~mfcc_array);
						~scaled_mfcc_buf = Buffer.alloc(s, 12);
						~params_buf = Buffer.alloc(s, 3);
						~mfcc_scaler.transformPoint(~mfcc_output_buf, ~scaled_mfcc_buf);
						~mlp.predictPoint(~scaled_mfcc_buf, ~params_buf);

						s.sync;

						Ndef(\send_prediction, {

							var values = FluidBufToKr.kr(~params_buf);
							var trig = Impulse.kr(~inferences_per_sec);

							SendReply.kr(trig:trig, cmdName:'/prediction', values:values);
						});

					}

				}, '\mfccs');

				OSCdef(\grab_params, {

					|msg|

					"********************************************".postln;
					" MLP predicted granular params from timbre: ".postln;
					"********************************************".postln;
					"".postln;
					("density: " ++ msg[4].asString ++ " grains per sec").postln;
					("grain overlap: " ++ msg[3].asString).postln;
					("detune: " ++ (msg[5].asInteger).asString ++ " semitones").postln;
					"".postln;


					Ndef(\grain_effect).set(
						\overlap, msg[3].abs, \trig_freq, msg[4].abs, \rate, 0 - msg[5].asInteger
					);

				}, '/prediction');
			}

			{~is_looping == 2} {

				~is_looping = 0;
				Ndef(\send_prediction).free;
				OSCdef(\grab_params).free;
				OSCdef(\set_params).free;
				Ndef(\send_mfccs).free;
			}
		}

		{~section_counter == 3 && msgs[0] == 11 && msgs[1] == 2} { ~is_concating = ~is_concating + 1;

			case

			{~is_concating == 1} {

				// add code for tree lookup here
				postln("k-d tree lookup");

				OSCdef(\find_neighbor,{
					~scaler.transformPoint(~mfccbuf, ~scaledbuf);
					~kdtree.kNearest(~scaledbuf,1,{
						arg nearest;
						var int = nearest.asString.split($-)[1].asInteger;

						~play_source_index.(int, ~solo_buffer, ~indices_buf, 0);
					});

					"".postln;
					"********************************************".postln;
					"***** K-D Tree nearest neighbour found *****".postln;
					"********************************************".postln;
					"".postln;

				},"/find-neighbor");

				~mfcc_listener = {
					arg mfccbuf;
					// var input = PlayBuf.ar(1,~target_buf,BufRateScale.ir(~target_buf),loop:1);
					var input = SoundIn.ar(0); // change to bus 1 if going through effects rig first
					var mfccs = FluidMFCC.kr(input,startCoeff:1);

					var trig = A2K.kr(
						Trig1.ar(
							FluidNoveltySlice.ar(
								input,
								algorithm:1,
								kernelSize:~kernel_size,
								threshold:~novelty_thresh,
								minSliceLength:10
					), ControlDur.ir));

					FluidKrToBuf.kr(mfccs,mfccbuf);

					SendReply.kr(trig,"/find-neighbor");

				}.play(args:[\mfccbuf,~mfccbuf]);
			}

			{~is_concating == 2} {

				~is_concating = 0;
				~mfcc_listener.free;
				OSCdef(\find_neighbour).free;
				"free k-d tree funcs".postln;
			}
		}

	}, ccNum:(1..7), chan:(0));
})
)