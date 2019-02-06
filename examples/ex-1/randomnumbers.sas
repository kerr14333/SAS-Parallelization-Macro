/********************************************************************
Title: A Hello World Program: Generating Random Numbers

Author: Chris Grieves

Description: This program is very simple and simply generates random numbers
             on each of the separate hosts. It includes many of the 
             useful macro variables provided by the macro so that the user 
             can see where they are being used.
	
*********************************************************************/

*point to where ever you have placed the distribute macro;
%include "X:\SAS-Parallelization-Macro\macro\distribute.sas";

*Number of workers we would like to spawn;
*this is not required, but helps;
%let processes = 3;

*assign number of jobs. THIS IS REQUIRED.;
%Let NIterAll=20; * => this should be equal to the number of domains we
                        want to run;

*assign chunk size. THIS IS REQUIRED.;
%let Niter=1; *=> number of domains in a batch;

*** NOTE: nbatches does not need to be defined since NIter is 1;



*We begin defining the %Rinit Macro.;
* RInit, FirstRSub and TaskRSub ARE REQUIRED FOR THE MACRO TO WORK;
%macro RInit;
	rsubmit remote=Host&iHost wait=yes macvar=Status&iHost;
		%macro FirstRSub;
			
			/***
			 Note, our task does not need anything complicated
		     So we may leave this blank;
		     ***/
					
		%mend;
		%macro TaskRSub;
			
			data nums;

				*assign batch number so we know what batch it came from;
				batch=&rem_batchnum.;

				*assign the host number so we know what host it came from;
				host=&rem_ihost.;

				*generate 200 random numbers;
				do i=1 to 200;
					x=rand('UNIFORM');
					drop i;
					output;
				end;
			run;


			proc append base=results data=nums force;
			run; 
			
			
		%mend;
	endrsubmit;
%mend;


%signon(processes=&processes.);


*start the work;
%distribute;


*before we sign off, collect results from each host;
%RCollect(from=results,to=results,n=&processes.);


*sign off the SAS workers 
 so they are not lingering background processes;
%signoff;
