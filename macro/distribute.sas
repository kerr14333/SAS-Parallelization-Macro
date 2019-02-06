/****************************************************************/
/* */
/* NAME: DISTRIBUTE */
/* TITLE: Distributed parallel processing in SAS using MP */
/* CONNECT */
/* SYSTEM: ALL */
/* PROCS: TEMPLATE */
/* PRODUCT: SAS/CONNECT */
/* DATA: */
/* */
/* SUPPORT: sasrdt UPDATE: 26FEB01 */
/* REF: See "Large-Scale Parallel Numerical Computation in */
/* the SAS System", Cheryl Doninger & Randy Tobias. */
/****************************************************************/
/*--------------------------------------------------------------------
The macros defined in this file are centered around the %Distribute
macro, which uses MP CONNECT tools from SAS/CONNECT software to employ
distributed processing for problems that consist of many replicate
runs of a fundamental task. For example, global integer optimization
problems are often solved by steepest ascent (the fundamental task)
with random restarts (the replicate runs). Similarly, Monte Carlo
methods in statistics rely on a set of pseudo-random observations (the
replicate runs) of one or more difficult-to-compute test statistics
(the fundamental task). If your problem can be factored in this way,
then %Distribute may offer a useful approach.
Besides running the fundamental task you specify the required
replicate number of times, %Distribute offers two additional
services:
- Problems of the type that %Distribute can handle often require
a stream of random numbers, and %Distribute creates and
manages such a stream for each host.
- In order to monitor your program, you would like to know
where your fundamental processing time is spent. So
%Distribute keeps track of how much time each host spends
working on its fundamental tasks and waiting for the client
to give it more work.
In order to use %Distribute system, you must first create the
following:
1. _Hosts data set - containing information about the hosts you
want to run on
2. %RInit macro - defining the programs to be run on each host
(1) says how to connect to and initialize to the hosts; (2) defines
the fundamental task to be performed on each host. Detailed
descriptions of the input is as follows:
_Hosts data set
Define a data set named _Hosts in the current WORK library with
an observation for each host you want to distribute the
computation to. For each observation, set two (character)
variables:
Variable Name Contents
Host Name of the host
Script signon script for host
These variables are used on the client, so make sure they are
valid names and paths in this environment
%RInit macro
This is what really defines the distributed computation. It
needs to wrap of (at least) two macro definitions
%FirstRSub - initialization on that host
%TaskRSub - the fundamental unit of distributed computation
within an RSUBMIT block, like so
%macro RInit;
rsubmit remote=Host&iHost wait=yes macvar=Status&iHost;
%macro FirstRSub;
<< Initialization for this host >>;
%mend;
%macro TaskRSub;
<< Fundamental unit of distributed computation >>;
%mend;
<< Optional additional initializations >>;
endrsubmit;
%mend;
It is your job to write the macros %FirstRSub and %TaskRSub so
that they define the fundamental task. As parameters for these
macros, you can assume the following global macro variables to
be available within the host SAS session:
Predefined host Contents
global macro
Rem_Host Name of this host
Rem_iHost Index of this host in _Host data set
Rem_NIter Size of chunk
Rem_Seed Random seed, rerandomized for each chunk
If you need other macro values (say, &Mac1, &Mac2, and &Mac3) to
be passed from the client to the host, you should specify them
in a %Macros macro, like so:
%macro Macros;
%syslput rem_Mac1=&Mac1;
%syslput rem_Mac2=&Mac2;
%syslput rem_Mac3=&Mac3;
%mend;
The %Distribute macro will take care of running this macro for
each of the hosts, so that you can use the macros &rem_Mac1,
&rem_Mac2, and &rem_Mac3 in your definitions of %FirstRSub and
%TaskRSub.
Once you have created the _Hosts data set and the %RInit macro, you can
distribute the fundamental task across all the hosts with just the
following four lines of code:
%SignOn;
%let NIterAll = <Size of entire problem>;
%let NIter = <Size of each chunk>;
%Distribute;
As chunks of the fundamental task are parceled out to the hosts, a
status line will be printed to the SAS log on the client, displaying
'.' for hosts that are currently working,
'!' for hosts that are currently waiting to be assigned work, and
'X' for hosts that are unable to do work for some reason.
Additional status information includes the number of fundamental tasks
submitted and completed so far. When the distribution is complete,
the system will display a breakdown of how much work was done on each
host, together with an over-all summary of the efficiency of the
distribution. Finally, you can
- use the %RCollect or %RCollectView macros to collect the
results from each host into a data set or DATA step view that
catenates all of them.
Further analysis of the collected results can be performed on the
client.
-----------------------------------------------------------------------
DISCLAIMER:
THIS INFORMATION IS PROVIDED BY SAS INSTITUTE INC. AS A SERVICE
TO ITS USERS. IT IS PROVIDED "AS IS". THERE ARE NO WARRANTIES,
EXPRESSED OR IMPLIED, AS TO MERCHANTABILITY OR FITNESS FOR A
PARTICULAR PURPOSE REGARDING THE ACCURACY OF THE MATERIALS OR CODE
CONTAINED HEREIN.
---------------------------------------------------------------------*/
/*
/ Name the files to which to write any log and listing produced by
/ the servers.
/---------------------------------------------------------------------*/
options nocenter autosignon=yes sascmd="sas -nonews -threads";

%let DistLog = distribute.log;
%let DistLst = distribute.lst;

/*
/ Options to control distribution-monitoring information:
/---------------------------------------------------------------------*/
%let DIST_DETAIL = 1; /* Print timing info from servers? */
%let DIST_STATUS = 1; /* Print periodic status lines for servers? */
%let DIST_DEBUG = 0; /* Print debugging information */

%*********************************************************************;
%* MACRO: SignOn *;
%* USAGE: %SignOn; *;
%* DESCRIPTION: *;
%* This macro signs on to the hosts, using the information in the *;
%* _Hosts data set. See comments above for a description. *;
%* NOTES: *;
%* Assumes _Hosts data set has been created correctly. *;
%* *;
%*********************************************************************;
%macro SignOn(processes=1);
	%local notesopt; 
	%let notesopt = %sysfunc(getoption(notes));
	options nonotes;

	data _Hosts;
		do i=1 to &processes.;
			Host=cat("process",i);
			output;
		end;
		drop i;
	run;
	/*
	/ Retrieve global host information from the _Hosts data set and set
	/ up Seed and Status variables for each host.
	/---------------------------------------------------------------------*/
	%global NumHosts;
	data _Hosts; 
	set _Hosts;
		Status = '!';
		iHost = _N_;
		call symput('NumHosts',trim(left(_N_)));
	run;

	%do iHost=1 %to &NumHosts;
		%global Host&iHost Status&iHost;
	%end;

	data _null_; 
	set _Hosts;
		call symput('Host'||trim(left(iHost)),trim(left(Host)) );
		call symput('Seed'||trim(left(iHost)),round(100000*ranuni(1)));
	run;

	data _null_; 
	set _Hosts;
		select (Status);
			when ('!') call symput('Status'||trim(left(iHost)),0);
			when ('X') call symput('Status'||trim(left(iHost)),1);
			when ('.') call symput('Status'||trim(left(iHost)),2);
		end;
	run;

	/*
	/ For each host, retrieve script, sign on, and set up a RLS libref
	/ to the host's work library.
	/---------------------------------------------------------------------*/
	%do iHost = 1 %to &NumHosts;
		%put Starting up Host&iHost = &&host&iHost;

		
		options notes;
		proc printto log="&DistLog" print="&DistLst"; run;

		signon process=Host&iHost;
		
		libname RWork&iHost slibref=WORK server=Host&iHost;

		%let Status&iHost = -1;
		%RInit;
		%let stimeropt = %sysfunc(getoption(stimer));
		options nostimer;

		proc printto; run;
		options &stimeropt;
		options nonotes;
	%end;
	/*
	/ Print the initial status of each host.
	/---------------------------------------------------------------------*/
	%let StatLine =;

	data _null_; 
	set _Hosts;
		call symput('StatLine',symget('StatLine')||trim(left(Status)));
	run;

	%put Stat: &StatLine;
	options &notesopt;
%mend;


%*********************************************************************;
%* MACRO: SignOff *;
%* USAGE: %SignOff; *;
%* DESCRIPTION: *;
%* This macro signs off the hosts. *;
%*********************************************************************;
%macro SignOff;
	%local notesopt; %let notesopt = %sysfunc(getoption(notes));
	options nonotes;

	data _null_; 
	set _Hosts;
		call symput('Host' ||trim(left(iHost)),trim(left(Host)) );
		call symput('NumHosts' ,trim(left(_n_)) );
		select (Status);
			when ('!') call symput('Status'||trim(left(iHost)),0);
			when ('X') call symput('Status'||trim(left(iHost)),1);
			when ('.','?') call symput('Status'||trim(left(iHost)),2);
		end;
	run;
	%do iHost = 1 %to &NumHosts;
		%put Stopping Host&iHost = &&host&iHost;
		options notes;
		proc printto log="&DistLog" print="&DistLst"; run;
		%let Status&iHost = -1;
		signoff process=Host&iHost macvar=Status&iHost;
		/*
		rsubmit remote=Host&iHost wait=yes macvar=Status&iHost;
		;
		endrsubmit;
		*/
		%let stimeropt = %sysfunc(getoption(stimer));
		options nostimer;
		proc printto; run;
		options &stimeropt;
		options nonotes;
	%end;
	%PrintStatus;
	options &notesopt;
%mend;

%*********************************************************************;
%* MACRO: _TaskRSub *;
%* USAGE: Internal macro only *;
%* DESCRIPTION: *;
%* This macro submits a chunk of the fundamental task to the host *;
%* with index nHost. *;
%* NOTES: *;
%* Assumes the macro %TaskRSub has been previously defined on the *;
%* host. Do this in the RInit macro defined on the client. *;
%*********************************************************************;
%macro _TaskRSub;
	%global DIST_DEBUG;
	%if (^&DIST_DEBUG) %then %do;
	proc printto log="&DistLog" print="&DistLst"; run;
	%end;
	%let Status&nHost = -1;
	/*
	/ Keep track of what's been submitted to each host *on* the
	/ hosts themselves, to ensure wires don't get crossed.
	/------------------------------------------------------------------*/
	rsubmit process=Host&nHost wait=yes;
		%nrstr(%%)let TaskNSubm = %eval(&TaskNSubm + &rem_niter);
		%nrstr(%%)sysrput NSubm&rem_iHost = &TaskNSubm;
	endrsubmit;
	%let rem_batchnum = %eval(&NSubm./&NIter.);
	%syslput rem_batchnum = &rem_batchnum.;
	/*
	/ Submit not only the task to this host, but also the random
	/ seed and time management code.
	/------------------------------------------------------------------*/
	rsubmit process=Host&nHost wait=no macvar=Status&nHost
		SYSRPUTSYNC=yes;

		data _null_;
			old_Seed = &rem_Seed;
			new_Seed = round(100000*ranuni(&rem_Seed));
			call symput('rem_Seed',trim(left(new_Seed)));
		run;

		data _TimeBetween;
			Host = "&rem_Host";
			now = datetime();
			call symput('_TimeStart_',now);
			TimeBetween = now - symget('_TimeEnd_');
		run;

		data _null_; 
			call symput('_TimeStart_',datetime()); 
		run;

		%TaskRSub;

		data _TimeEnd;
			Host = "&rem_Host";
			now = datetime();
			call symput('_TimeEnd_',now);
			Time = now - symget('_TimeStart_');
		run;

		data _Time; 
		merge _TimeBetween _TimeEnd;
		run;

		data _TimeAll; 
			set _TimeAll _Time;
		run;

		%nrstr(%%)let TaskNDone = %eval(&TaskNDone + &rem_niter);
		%nrstr(%%)sysrput NDone&rem_iHost = &TaskNDone;
	endrsubmit;

	%let NSubm = %eval(&NSubm + &NIter);

	%if (^&DIST_DEBUG) %then %do;
		options nostimer; proc printto; run; options stimer;
	%end;
%mend;
%*********************************************************************;
%* MACRO: PrintStatus *;
%* USAGE: Internal macro only *;
%* DESCRIPTION: *;
%* This macro prints a line summarizing the current status of *;
%* each server: *;
%* '.' for hosts that are currently working, *;
%* '!' for hosts that are currently waiting to be assigned *;
%* work, and *;
%* 'X' for hosts that are unable to do work for some reason. *;
%* Additional status information includes the number of *;
%* fundamental tasks submitted and completed so far. *;
%*********************************************************************;
%macro PrintStatus;
	%local notesopt; 
	%let notesopt = %sysfunc(getoption(notes));
	options nonotes;

	data _Hosts; 
	set _Hosts;
		xStatus = 1*symget('Status'||trim(left(iHost)));
		select (xStatus);
			when (0) Status = '!';
			when (1) Status = 'X';
			when (2) Status = '.';
			otherwise do; Status = '?'; put iHost= xStatus=; end;
		end;
		NSubm = 1*symget('NSubm'||trim(left(iHost)));
		NDone = 1*symget('NDone'||trim(left(iHost)));
	run;

	%let StatLine =;

	data _null_;
	set _Hosts;
		call symput('StatLine',symget('StatLine')||trim(left(Status)));
	run;

	proc summary data=_Hosts;
		var NSubm NDone;
		output out=_SHosts sum=NSubm NDone;
	run;

	data _null_; 
	set _SHosts;
		call symput('StatLine',symget('StatLine')
		||': ('||trim(left(put(NSubm ,best20.)))
		||',' ||trim(left(put(NDone ,best20.)))
		||')/' ||trim(left(put(&NIterAll,best20.))));
	run;

	%put Stat: &StatLine;

	options &notesopt;
%mend;

%*********************************************************************;
%* MACRO: Distribute *;
%* USAGE: %Distribute *;
%* DESCRIPTION: *;
%* This macro performs the actual distribution, assuming that you *;
%* have first created the _Hosts data set and the %RInit macro, *;
%* as described in the header comments above. *;
%*********************************************************************;
%macro Distribute;

	%global DIST_DETAIL DIST_STATUS DIST_DEBUG;

	%do iHost=1 %to &NumHosts;
		%global Host&iHost Seed&iHost Status&iHost NSubm&iHost NDone&iHost
		TimeWork&iHost TimeWait&iHost TimeFreq&iHost _ElapsedTime;
	%end;

	%if (^&DIST_DEBUG) %then %do;
		%local notesopt; %let notesopt = %sysfunc(getoption(notes));
		options nonotes;
	%end;
	%else %do;
		options mprint mtrace;
	%end;

	/*
	/ Start the timer.
	/---------------------------------------------------------------------*/
	data _null_; 
		call symput('TimeStart',trim(left(datetime()))); 
	run;
	/*
	/ Set up macro variables with the names and random number seeds for
	/ all the hosts, and initialize monitoring information.
	/---------------------------------------------------------------------*/
	data _null_; 
	set _Hosts;
		call symput('Host' ||trim(left(iHost)),
		trim(left(Host)) );

		call symput('Seed' ||trim(left(iHost)),
		trim(left(round(100000*ranuni(1)))));

		call symput('NumHosts' ,
		trim(left(_N_)) );

		select (Status);
			when ('!') call symput('Status'||trim(left(iHost)),0);
			when ('X') call symput('Status'||trim(left(iHost)),1);
			when ('.') call symput('Status'||trim(left(iHost)),2);
		end;
		call symput('NSubm' ||trim(left(iHost)),'0');
		call symput('NDone' ||trim(left(iHost)),'0');
	run;

	%let NSubm = 0;
	/*
	/ Start-up phase: submit the initialization task to each host, and
	/ also the first fundamental task.
	/---------------------------------------------------------------------*/
	%do iHost = 1 %to &NumHosts;
		%if (^&DIST_DEBUG) %then %do;
			proc printto log="&DistLog" print="&DistLst"; run;
		%end;

		options process=Host&iHost;

		%syslput rem_Host =&&host&iHost;
		%syslput rem_Seed =&&seed&iHost;
		%syslput rem_niter =&niter;
		%syslput rem_iHost =&iHost;
		*assign work directory of parent session;
		%syslput homework=%sysfunc(pathname(work));

		%Macros;

		rsubmit process=Host&iHost wait=yes;
			libname homework "&homework.";
			%FirstRSub;

			data _null_;
				now = datetime();
				call symput('_TimeEnd_',now);
			run;
			data _TimeAll; if (0); run;

			%nrstr(%%)let TaskNSubm = 0;
			%nrstr(%%)sysrput NSubm&rem_iHost = &TaskNSubm;
			%nrstr(%%)let TaskNDone = 0;
			%nrstr(%%)sysrput NDone&rem_iHost = &TaskNDone;
		endrsubmit;

		%let nHost = &iHost;
		%_TaskRSub;

		%if (^&DIST_DEBUG) %then %do;
			options nostimer; proc printto; run; options stimer;
		%end;
		%if (&DIST_STATUS) %then %PrintStatus;

		%let NSubm = 0;
		%let NDone = 0;

		%do jHost = 1 %to %eval(&iHost);
			%let NSubm = %eval(&NSubm + &&NSubm&jHost);
			%let NDone = %eval(&NDone + &&NDone&jHost);
		%end;
		%do jHost = 1 %to %eval(&iHost);
			%let LastStat&jHost = &&Status&jHost;
		%end;

		/*
		/ We also recycle through previous hosts here, resubmitting tasks
		/ to them if they're ready for more: this saves a little time
		/ when some hosts finish their first task before the start-up
		/ phase is complete.
		/------------------------------------------------------------------*/
		%do jHost = 1 %to %eval(&iHost);
			%if ((&&LastStat&jHost = 0) & (&NDone < &niterall)) %then %do;
				%let nHost = &jHost; %_TaskRSub;
			%end;
		%end;
	%end;

	%if (&DIST_STATUS) %then %PrintStatus;
	%let NSubm = 0;
	%let NDone = 0;

	%do jHost = 1 %to %eval(&NumHosts);
		%let NSubm = %eval(&NSubm + &&NSubm&jHost);
		%let NDone = %eval(&NDone + &&NDone&jHost);
	%end;

	/*
	/ Monitor the MACVARs Status1, Status2, etc. to watch the jobs
	/ finish. As they do, resubmit new tasks for free hosts to work on.
	/---------------------------------------------------------------------*/
	%let Running = 1;

	%do %while(%length(&Running));
		waitfor _any_
		%do iHost = 1 %to &NumHosts;
			%if (&&LastStat&iHost = 2) %then %do;
				Host&iHost
			%end;
		%end;
		;
		%if (&DIST_STATUS) %then %PrintStatus;

		%let NSubm = 0;
		%let NDone = 0;
		%do jHost = 1 %to %eval(&NumHosts);
			%let NSubm = %eval(&NSubm + &&NSubm&jHost);
			%let NDone = %eval(&NDone + &&NDone&jHost);
		%end;
		%let Running =;
		%do iHost = 1 %to &NumHosts;
			%let LastStat&iHost = &&Status&iHost;
			%if (&&LastStat&iHost = 2) %then %let Running =&Running &iHost;
		%end;

		%do iHost = 1 %to &NumHosts;
			%if ((&&LastStat&iHost = 0) & (&NSubm < &niterall)) %then %do;
				%let nHost = &iHost; %_TaskRSub;
				%let LastStat&iHost = &&Status&iHost;
				%if (&&LastStat&iHost = 2) %then %let Running =&Running &iHost;
				%let NSubm = 0;
				%let NDone = 0;
				%do jHost = 1 %to %eval(&NumHosts);
					%let NSubm = %eval(&NSubm + &&NSubm&jHost);
					%let NDone = %eval(&NDone + &&NDone&jHost);
				%end;
			%end;
		%end;
	%end; /*end Running*/
	/*
	/ All tasks are finished: retrieve the timing information from each
	/ of the hosts, ...
	/---------------------------------------------------------------------*/
	%do iHost = 1 %to &NumHosts;

		%let LastStat&iHost = &&Status&iHost;

		%if (&&LastStat&iHost = 0) %then %do;
			%if (^&DIST_DEBUG) %then %do;
				proc printto log="&DistLog" print="&DistLst"; run;
			%end;
			rsubmit process=Host&iHost wait=yes;

				proc summary data=_TimeAll;
					var Time TimeBetween;
					output out=_TimeSumm mean=Work Wait;
				run;

				data _null_; 
				set _TimeSumm;
					call symput('_TimeWork',trim(left(Work)));
					call symput('_TimeWait',trim(left(Wait)));
					call symput('_TimeFreq',trim(left(_FREQ_ )));
				run;
				%nrstr(%%)sysrput TimeWork&rem_iHost = &_TimeWork;
				%nrstr(%%)sysrput TimeWait&rem_iHost = &_TimeWait;
				%nrstr(%%)sysrput TimeFreq&rem_iHost = &_TimeFreq;
			endrsubmit;

			%if (^&DIST_DEBUG) %then %do;
				options nostimer; proc printto; run; options stimer;
			%end;
		%end;
	%end;
	/*
	/ ... add it to the _Hosts data set, ...
	/---------------------------------------------------------------------*/
	data _null_;
		Elapse = datetime() - &TimeStart;
		call symput('_ElapsedTime',trim(left(put(Elapse,best.))));
	run;

	data TimeSumm; 
	set _Hosts(keep=Host iHost);
		keep iHost Host NIter TimeWork EstElapsed Eff TimeWait TotalWork TotalWait;

		NIter = &NIter*symget('TimeFreq'||trim(left(iHost)));
		TimeWork = 1*symget('TimeWork'||trim(left(iHost)));
		TimeWait = 1*symget('TimeWait'||trim(left(iHost)));
		EstElapsed = (&NIterAll/&NIter)*TimeWork;
		Eff = (EstElapsed/&_ElapsedTime)/&NumHosts;
		TotalWork = (NIter/&NIter)*TimeWork;
		TotalWait = (NIter/&NIter)*TimeWait;
	run;
	/*
	/ ... and report it.
	/---------------------------------------------------------------------*/
	%if (&DIST_DETAIL) %then %do;
		proc sort data=TimeSumm out=TimeSumm; by descending TimeWork;
		proc print data=TimeSumm label noobs;
		format TimeWork time.;
		format TimeWait time.;
		format EstElapsed time.;
		format Eff percent.;
		label NIter = "No. Iter";
		label TimeWork = "Work Time/&Niter Iter";
		label TimeWait = "Wait Time/&Niter Iter";
		label EstElapsed = "Estimated Time for Entire Problem";
		label Eff = "Distribution Efficiency";
		var iHost Host NIter TimeWork EstElapsed Eff TimeWait;
		run;
	%end;

	proc summary data=TimeSumm;
		var TotalWork TotalWait;
		output out=TotalTime Sum=TotalWork TotalWait;
	run;

	data _null_; 
	set TotalTime;
		Elapsed = &_ElapsedTime;
		Eff = (TotalWork/Elapsed)/&NumHosts;
		put " ";
		put " Total elapsed time: " Elapsed time.;
		put " Cumulative working time: " TotalWork time.;
		put " Cumulative waiting time: " TotalWait time.;
		put " Scaling efficiency: " Eff percent8.2;
		put " ";
		put " ";
	run;

	%if (^&DIST_DEBUG) %then %do;
		options &notesopt;
	%end;
%mend;
%*********************************************************************;
%* MACRO: RCollect *;
%* USAGE: %RCollect(<<Remote DS prefix>>,<<Client DS>>); *;
%* DESCRIPTION: *;
%* This macro collects similarly named data sets from &n *;
%* libraries named RWork1, ..., RWork&n, into a single data set. *;
%* NOTES: *;
%* In order to use a view to virtually collect the data sets, use *;
%* 'dsname / view=dsname' as the client data set name. *;
%*********************************************************************;
%macro RCollect(from,to,n=);
	%global NumHosts;
	%if (^%length(%left(%trim(&n)))) %then %let n=&NumHosts;
	%do iHost=1 %to &NumHosts;
	%global Host&iHost Status&iHost;
	%end;
	data &to;
	set
	%do i=1 %to &N;
	%if (&&Status&i = 0) %then %do;
	RWork&i..&from
	%end;
	%end;
	;
	run;
%mend;
