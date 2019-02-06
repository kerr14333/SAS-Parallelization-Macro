/********************************************************************
Title: Parallelizing Regression over several domains

Author: Chris Grieves

Description: In this example, I use simulated (y,x) data over "domains" 0 to 200
             and fit the regression model x=a+b*x in each domain. Our result are
             the model parameters a and b and the RMSE for each domain. Although this 
             example does not speed up your processing time because it is already
             very fast to fit linear regression models, it demonstrates the 
             process when the modeling process could take a significant amount of 
             time to fit (for example Bayesian models or non-parametric regression 
             models).	
*********************************************************************/

*point to where ever you have placed the distribute macro;
%include "X:\SAS-Parallelization-Macro\macro\distribute.sas";

*Number of workers we would like to spawn;
*this is not required, but helps;
%let processes = 3; 


*read in data we want to model;
*this is example data that I have simulated;
*it is simply a domain, with a set of y and x's;
data regdata;
	infile "X:\SAS-Parallelization-Macro\examples\ex-1\regdata.csv" 
	firstobs=2 
	dlm=",";
	input domain x y;
run;


*create a list of domains, we will use this to
 assign jobs to workers, subset, and batch the 
 data; 
*if there is more than one key variable (for example state/county)
 make sure to include it in the by statement;
proc sort data= regdata out=domains (keep=domain) nodupkey;
by domain;
run;


*get number of jobs (equal to the number of domains in our case);
data _NULL_;
	if 0 then set domains nobs=n;
	call symputx('nrows',n);
	stop;
run;


*assign number of jobs. THIS IS REQUIRED.;
%Let NIterAll=&nrows.; * => this should be equal to the number of domains we
                        want to run;

*assign chunk size. THIS IS REQUIRED.;
%let Niter=10; *=> number of domains in a batch;
%let Nbatches=%sysfunc(ceil(&niterall./&niter.));  * => number of batches = 
                                                        ceil((JOBS)/(JOBS per BATCH))= 
                                                       ceil(Niterall/Niter) = 20);
                                                    *NOT required, but helpful

*assign the batch numbers to domains;
*we do this by using row $ modulus the number of jobs;
*this results in batch numbers 0 to 19 in this case;
data domains;
set domains;
batchnum=mod(_N_,&nbatches.);
run;

*We begin defining the %Rinit Macro.;
* RInit, FirstRSub and TaskRSub ARE REQUIRED FOR THE MACRO TO WORK;
%macro RInit;
	rsubmit remote=Host&iHost wait=yes macvar=Status&iHost;
		%macro FirstRSub;
			
			*define the task we will do on each run;
		    *in this instance, we are running a regression on a single domain;
			%macro runRegression(domain=);
				
				*run regression ;
				proc reg data=homework.regdata (where=(domain=&domain.))
                         outest=results (rename=(x=X_coef) drop=y) noprint;
					by domain;
					model y=x;
				run;
				
				*append to ongoign results dataset;
				*we output this to the main work directory of the parent;
				proc append data=results base=homework.results&rem_ihost. force;
				run;
			%mend runRegresssion;
					
		%mend;
		%macro TaskRSub;
			
		
			*use data step to loop through domains;
			*we use rem_batch num to subset to the;
			*domains assigned to this batch;
			*we then use call execute to ;
			data _null_;
			set homework.domains;
				where batchnum=&rem_batchnum.;
				code=catt('%nrstr(%runRegression(domain=',domain,'))');
				call execute(code);
			run;
			
		%mend;
	endrsubmit;
%mend;

*sign on the processes;
*you should see messages in the log 
 telling you each processes is signing on
 and stat !!! indicating that they are 
 ready to receive instructions;
%signon(processes=&processes.);


*start the work;
%distribute;

*sign off the SAS workers 
 so they are not lingering background processes;
%signoff;

*create a macro to set all the results 
 together;
%macro collect;
	data results;
		*use loop to generate the name of each result set;
		set 
		%do i=1 %to &processes.;
			results&i.
		%end;
		; *closing semicolon for set statement;
	run;
	
	*delete the temporary individual results datasets;
	proc delete data=results1- results&processes.;
	run;
	quit;	
%mend collect;
%collect; 

*just sort by domain to make it look pretty;
proc sort data=results;
by domain;
run;
