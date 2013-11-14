%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%         DATA PROCESSING for Application in OpenSim main function        %
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
% Implemented by Alice Mantoan, August 2012, <alice.mantoan@dei.unipd.it>
% Last version February 2013
%--------------------------------------------------------------------------

function []=runDataProcessing(ElaborationFilePath)

if nargin==0
    error('elaboration.xml file path missing: it must be given as a function input')
end

h = waitbar(0,'Elaborating data...Please wait!');

%% -----------------------PROCESSING SETTING-------------------------------
% Acquisition info loading, folders paths and parameters generation
%--------------------------------------------------------------------------

[foldersPath,parameters]= DataProcessingSettings(ElaborationFilePath);

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                      OPENSIM Files Generation
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%Parameters List: Ri-nomination 
trialsList=parameters.trialsList;   

if isfield(parameters,'fcut')
    fcut=parameters.fcut;
end

WindowsSelection=parameters.WindowsSelection;
StancesOnFP=parameters.StancesOnFP;

trcMarkersList=parameters.trcMarkersList;

globalToOpenSimRotations=parameters.globalToOpenSimRotations;
FPtoGlobalRotations=parameters.FPtoGlobalRotations;

%Create Trails Output Dir
foldersPath.trialOutput= mkOutputDir(foldersPath.elaboration,trialsList);

%% ------------------------------------------------------------------------
%                            DATA LOADING 
%                   .mat data from SessionData Folder
%--------------------------------------------------------------------------
%loadMatData includes check for markers unit (if 'mm' ok else convert)
%Frames contains indication of first and last frame of labeled data, that
%must be the same for Markers and Analog Data and depends on the tracking
%process
[MarkersRawData, Frames]=loadMatData(foldersPath.sessionData, trialsList, 'Markers');
AnalogRawData=loadMatData(foldersPath.sessionData, trialsList, 'Forces');

%Loading FrameRates
load([foldersPath.sessionData 'Rates.mat']) 

VideoFrameRate=Rates.VideoFrameRate;
AnalogFrameRate=Rates.AnalogFrameRate;

%Loading ForcePlatformInfo
load([foldersPath.sessionData 'ForcePlatformInfo.mat'])
nFP=length(ForcePlatformInfo);

%Loading AllTrialsName
load([foldersPath.sessionData 'trialsName.mat'])

%Loading All Markers Labels (Raw)
load([foldersPath.sessionData 'MLabels.mat'])

disp('Data have been loaded from mat files')         

%% ------------------------------------------------------------------------
%                     Preparing Data for Filtering
%--------------------------------------------------------------------------

%-------------------------Markers Selection--------------------------------
%markers to be written in the trc file: only those are processed
for k=1:length(trialsList)
    markerstrc{k} = selectingMarkers(trcMarkersList,MLabels,MarkersRawData{k});
end
%-----------Check for markers data missing and Interpolation--------------

[MarkersNan,index]=replaceWithNans(markerstrc);
 
%if there are no missing markers, it doesn't interpolate
[interpData,note] = DataInterpolation(MarkersNan, index);
 
writeInterpolationNote(note,foldersPath.trialOutput);
%interpData=markerstrc;
%------------------------Analog Data Split---------------------------------
%Analog data are organized like this:
%ForcePlatform type 1: [Fx1 Fy1 Fz1 Px1 Py1 Mz1 Fx2 Fy2 Fz2 Px2 Py2 Mz2...]
%ForcePlatform type 2: [Fx1 Fy1 Fz1 Mx1 My1 Mz1 Fx2 Fy2 Fz2 Mx2 My2 Mz2...]
%ForcePlatform type 3: [F1x12 F1y23 F1y14 F1y23 F1z1 F1z2 F1z3 F1z4 ...]

%Separation of information for different filtering taking into account
%differences in force platform type

[Forces,Moments,COP]= AnalogDataSplit(AnalogRawData,ForcePlatformInfo);

waitbar(1/7);    

%% ------------------------------------------------------------------------
%                         DATA FILTERING 
%--------------------------------------------------------------------------
%filter parameters: only fcut can change, order and type of filter is fixed
%Output: structure with filtered data from all selected trials

%----------------------------Markers---------------------------------------
if (exist('fcut','var') && isfield(fcut,'m'))
   %filtMarkers=DataFiltering(MarkersRawData,VideoFrameRate,fcut.m);
   filtMarkers=DataFiltering(interpData,VideoFrameRate,fcut.m);
   filtMarkersCorrected=correctBordersAfterFiltering(filtMarkers,interpData,index);
   %filtMarkersCorrected=filtMarkers;
else
    filtMarkersCorrected=interpData;
    %filtMarkersCorrected=MarkersRawData;
    %filtMarkersCorrected=markerstrc;
end
 
%----------------------------Analog Data-----------------------------------

if (exist('fcut','var') && isfield(fcut,'f'))
    filtForces=DataFiltering(Forces,AnalogFrameRate,fcut.f);
    filtMoments=DataFiltering(Moments,AnalogFrameRate,fcut.f);
else
    filtForces=Forces;
    filtMoments=Moments;
end
        
if (ForcePlatformInfo{1}.type==2 || ForcePlatformInfo{1}.type==3 || ForcePlatformInfo{1}.type==4) %FP return Moments (type 2: UWA case) 
    
    %In this case, COP have to be computed
    %Necessary Thresholding for COP computation
    [ForcesThr,MomentsThr]=FzThresholding(filtForces,filtMoments);

    for k=1:length(filtMoments)
        for i=1:nFP
            COP{k}(:,:,i)=computeCOP(ForcesThr{k}(:,:,i),MomentsThr{k}(:,:,i), ForcePlatformInfo{i});          
        end
    end
    
    filtCOP=COP; %not necessary to filter the computed cop
    
else if (ForcePlatformInfo{1}.type==1)  %Padova type: it returns Px & Py
        
    if (exist('fcut','var') && isfield(fcut,'cop'))
        
        filtCOP=CopFiltering(COP,AnalogFrameRate,fcut.cop);       
    else 
        filtCOP=COP;
    end

    %Threasholding also here for uniformity among the two cases
    [ForcesThr,MomentsThr]=FzThresholding(filtForces,filtMoments);
    end
end

disp('Data have been filtered')
%For next steps, only filtered data are kept                                                  
%clear MarkersRawData ForcesRawData EMGRawData
waitbar(2/7);   
%% ------------------------------------------------------------------------
%                      START/STOP COMPUTATION
%--------------------------------------------------------------------------
%Different AnalysisWindow computation methods may be implemented according
%to the application
%To select the AnalysisWindow, noise Thresholded Forces are used
AnalysisWindow=AnalysisWindowSelection(WindowsSelection,StancesOnFP,filtForces,Frames,Rates);

saveAnalysisWindow(foldersPath.trialOutput,AnalysisWindow)

%% ------------------------------------------------------------------------
%                        DATA WINDOW SELECTION
%--------------------------------------------------------------------------
[MarkersFiltered,Mtime]=selectionData(filtMarkersCorrected,AnalysisWindow,VideoFrameRate);
[ForcesFiltered,Ftime]=selectionData(ForcesThr,AnalysisWindow,AnalogFrameRate);
[MomentsFiltered,Ftime]=selectionData(MomentsThr,AnalysisWindow,AnalogFrameRate);
[COPFiltered,Ftime]=selectionData(filtCOP,AnalysisWindow,AnalogFrameRate);

%DataRaw selection for plotting
[ForcesSelected]=selectionData(Forces,AnalysisWindow,AnalogFrameRate);
[MomentsSelected]=selectionData(Moments,AnalysisWindow,AnalogFrameRate);
[COPSelected]=selectionData(COP,AnalysisWindow,AnalogFrameRate);

%% --------------------------------------------------------------------------
%                           Results plotting
%--------------------------------------------------------------------------
ResultsVisualComparison(ForcesSelected,ForcesFiltered,foldersPath.trialOutput,'Forces')
ResultsVisualComparison(MomentsSelected,MomentsFiltered,foldersPath.trialOutput,'Moments')
ResultsVisualComparison(COPSelected,COPFiltered,foldersPath.trialOutput,'COP')

%% ------------------------------------------------------------------------
%                     SAVING Filtered Selected Data
%--------------------------------------------------------------------------
saveFilteredData(foldersPath.trialOutput, Mtime, MarkersFiltered,'Markers')
saveFilteredData(foldersPath.trialOutput, Ftime, ForcesFiltered,'Forces')
saveFilteredData(foldersPath.trialOutput, Ftime, MomentsFiltered,'Moments')
saveFilteredData(foldersPath.trialOutput, Ftime, COPFiltered,'COP')
waitbar(3/7);   

%% ------------------------------------------------------------------------
%                           WRITE TRC
%--------------------------------------------------------------------------

load([foldersPath.sessionData 'MLabels.mat'])
  
for k=1:length(trialsList)

    FullFileName=[foldersPath.trialOutput{k} trialsList{k} '.trc'];
    %markers selection anticipates at the beginning to avoid processing 
    %useless data and problems with interpolation
    %markerstrc = selectingMarkers(trcMarkersList,MLabels,MarkersFiltered{k});
    %createtrc(markerstrc,Mtime{k},trcMarkersList,globalToOpenSimRotations,VideoFrameRate,FullFileName)
    createtrc(MarkersFiltered{k},Mtime{k},trcMarkersList,globalToOpenSimRotations,VideoFrameRate,FullFileName)    
end

waitbar(4/7);   
%% ------------------------------------------------------------------------
%                           WRITE MOT
%--------------------------------------------------------------------------

for k=1:length(trialsList)
    
    globalMOTdata{k}=[];
    
    for i=1:nFP
        
        Torques{k}(:,:,i)= computeTorque(ForcesFiltered{k}(:,:,i),MomentsFiltered{k}(:,:,i), COPFiltered{k}(:,:,i), ForcePlatformInfo{i});
        
        globalForces{k}(:,:,i)= RotateCS (ForcesFiltered{k}(:,:,i),FPtoGlobalRotations(i));
        globalTorques{k}(:,:,i)= RotateCS (Torques{k}(:,:,i),FPtoGlobalRotations(i));
        globalCOP{k}(:,:,i) = convertCOPToGlobal(COPFiltered{k}(:,:,i),FPtoGlobalRotations(i),ForcePlatformInfo{i});
        
        globalMOTdata{k}=[globalMOTdata{k} globalForces{k}(:,:,i) globalCOP{k}(:,:,i) ];        
    end
    
    for i=1:nFP
        
        globalMOTdata{k}=[globalMOTdata{k} globalTorques{k}(:,:,i) ];      
    end
      
    %Rotation for OpenSim
    
    MOTdataOpenSim{k}=RotateCS (globalMOTdata{k},globalToOpenSimRotations);
    
    %Write MOT
    FullFileName=[foldersPath.trialOutput{k} trialsList{k} '.mot'];
        
    writeMot(MOTdataOpenSim{k},Ftime{k},FullFileName)
end

waitbar(5/7);

%save_to_base(1)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                           EMG PROGESSING
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
disp(' ')
disp('%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%')
disp('             EMG PROCESSING                    ')
disp('%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%')
%Data needed:
%foldersPath,trialsName,trialsList,EMGRawData,AnalogFrameRate,EMGLabels, 
%AnalysisWindow,EMGOffset,MaxEmgTrialsList,EMGsSelected_C3DLabels,
%EMGsSelected_OutputLabels

%Ri-nomination from parameters

if isfield(parameters,'EMGsSelected')
    EMGsSelected_OutputLabels= parameters.EMGsSelected.OutputLabels;
    EMGsSelected_C3DLabels= parameters.EMGsSelected.C3DLabels;
    EMGOffset=parameters.EMGOffset;
end

if isfield(parameters,'MaxEmgTrialsList')
    MaxEmgTrialsList=parameters.MaxEmgTrialsList;
end

%Loading EMG Raw
EMGRawData=loadMatData(foldersPath.sessionData, trialsList, 'EMG');

%Loading EMG for Max Computation
if isequal(parameters.MaxEmgTrialsList,parameters.trialsList)
    EMGRawForMax=EMGRawData;
else 
    EMGRawForMax=loadMatData(foldersPath.sessionData, MaxEmgTrialsList, 'EMG');
end

%Loading EMGLabels
load([foldersPath.sessionData 'EMGLabels.mat'])
  
%If there are EMGs --> processing
if (isempty(EMGRawData)==0 && isempty(EMGLabels)==0)
%% ------------------------------------------------------------------------
%                           MUSCLES SELECTION
%                  and EMGs Arrangement for the Output file
%--------------------------------------------------------------------------
    EMGselectionIndexes=findIndexes(EMGLabels,EMGsSelected_C3DLabels);
    
    for k=1:length(trialsList)
        
        EMGsSelected{k}=EMGRawData{k}(:,EMGselectionIndexes);
    end
    
    %EMGsSelectedForMax are the same because max is needed for normalization of
    %the selected emgs, what change are the trials we consider for computation
    
    for k=1:length(MaxEmgTrialsList)
        
        EMGsSelectedForMax{k}=EMGRawForMax{k}(:,EMGselectionIndexes);
    end

%% ------------------------------------------------------------------------
%                       EMG FILTERING: ENVELOPE
%--------------------------------------------------------------------------
    %fcut for EMG assumed fixed (6Hz)
    EMGsEnvelope=EMGFiltering(EMGsSelected,AnalogFrameRate);
    
    EMGsEnvelopeForMax=EMGFiltering(EMGsSelectedForMax,AnalogFrameRate);

%% ------------------------------------------------------------------------
%                      EMG ANALYSIS WINDOW SELECTION
%--------------------------------------------------------------------------
  
    [EMGsFiltered,EMGtime]=selectionData(EMGsEnvelope,AnalysisWindow,AnalogFrameRate,EMGOffset);
    
    %if trials for max computation are the same of those for elaboration, max
    %values are computed within the same analysis window, else all signals are
    %considered
    if isequal(MaxEmgTrialsList,trialsList)
        
        EMGsForMax=selectionData(EMGsEnvelopeForMax,AnalysisWindow,AnalogFrameRate,EMGOffset);
    else
        EMGsForMax=EMGsEnvelopeForMax;
    end
    
    %SAVING and PLOTTING
       
    if isfield(WindowsSelection,'Offset') 
        %if there's an offset, the Analysis Window is a Stance Phase
        EnvelopePlotting(EMGsFiltered,EMGsSelected_C3DLabels, foldersPath.trialOutput, AnalogFrameRate,EMGOffset,WindowsSelection.Offset)
    else
        EnvelopePlotting(EMGsFiltered,EMGsSelected_C3DLabels, foldersPath.trialOutput, AnalogFrameRate,EMGOffset)
    end
    waitbar(6/7);
%% ------------------------------------------------------------------------
%                        COMPUTE MAX EMG VALUES
%--------------------------------------------------------------------------
    MaxEMGvalues=computeMaxEMGvalues(EMGsForMax);
    disp('Max values for selected emg signals have been computed')
    
    %print maxemg.txt
    printMaxEMGvalues(foldersPath.elaboration, EMGsSelected_C3DLabels, MaxEMGvalues);
    
    disp('Printed maxemg.txt')

%% ------------------------------------------------------------------------
%                            NORMALIZE EMG
%--------------------------------------------------------------------------
    NormEMG=normalizeEMG(EMGsFiltered,MaxEMGvalues);

%% ------------------------------------------------------------------------
%                            PRINT emg.txt
%--------------------------------------------------------------------------
    
    for k=1:length(trialsList)
        
        printEMGtxt(foldersPath.trialOutput{k},EMGtime{k},NormEMG{k},EMGsSelected_OutputLabels);
    end
    
    disp('Printed emg.txt' )
    
    waitbar(7/7);
    close(h)
    
    save_to_base(1)
    % save_to_base() copies all variables in the calling function to the base
    % workspace. This makes it possible to examine this function internal
    % variables from the Matlab command prompt after the calling function
    % terminates. Uncomment the following command if you want to activate it
%% ------------------------------------------------------------------------
%                           PLOTTING EMG
%--------------------------------------------------------------------------
    plotEMGChoice = questdlg('Do you want to plot EMGs Raw', ...
        'Plotting EMGs', ...
        'Yes','No','Yes');
    
    if strcmp(plotEMGChoice,'Yes')
        
        EMGsPlotting(EMGsSelected,EMGsEnvelope,AnalysisWindow,EMGsSelected_C3DLabels, foldersPath.trialOutput, AnalogFrameRate)
        disp('Plotted EMGs')
    end

else
    waitbar(6/7);   
    disp('No emg raw data to be processed')
    waitbar(7/7);   
end
%-------------------------------------------------------------------------

h = msgbox('Data Processing terminated successfully','Done!');
uiwait(h)


