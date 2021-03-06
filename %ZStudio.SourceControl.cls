Class %ZStudio.SourceControl Extends %Studio.SourceControl.File
{

/// Return the name of this item without the prefix to be added by ExtName
ClassMethod Name(InternalName As %String) As %String [ Private ]
{
    If $data(^Sources)'=11 Quit ""
        
    If $$CheckProtect^%qccServer(InternalName) Quit ""
    
    Set nam=$p(InternalName,".",1,$l(InternalName,".")-1),ext=$p(InternalName,".",$l(InternalName,".")),ext=$zcvt(ext,"l")
    If nam="" Quit ""
    If ext="prj",nam["Default_" Quit ""
    If ext="cls",$$$defClassKeyGet(nam,$$$cCLASSgeneratedby)'="" Quit ""

    If ext="cls"||(ext="prj")||(##class(%RoutineMgr).UserType(InternalName)) {
        Quit $translate($translate(nam,".%","/")_"."_ext_".xml","\","/")
    }
    Quit $translate($tr(nam,"%.","_/")_"."_ext_".xml","\","/")
}

Method OnAfterCompile(InternalName As %String) As %Status
{
    set tSC = ##super(InternalName)
    if $$$ISOK(tSC) {
        set tSC = ..SonarLint(InternalName)
    }
    quit tSC
}

Method SonarLint(InternalName As %String) As %Status
{
	set ext=$zcvt($p(InternalName, ".", *),"l")
	if ext'="cls" quit $$$OK

    set resName="sonarLint"_$job
	if '$system.Event.Defined(resName) {
		do $system.Event.Create(resName)
	}

    set forStudio='$isobject($get(%request))

    job ..SonarLintJob(InternalName, resName, forStudio)
    set child=$zchild
    
    write !!,"-------------  SonarLint  -------------",!
    for {
    	set $lb(sc,data)=$system.Event.WaitMsg(resName, 2)
    	if sc<=0 {
    		quit:'$data(^$JOB(child))
    		continue
    	}
    	
		write !,data
    } 
    write !!,"-------------------------------------------",!
	do $system.Event.Delete(resName)
    
    quit $$$OK
}

ClassMethod SonarLintJob(InternalName As %String, ResourceName As %String = "", forStudio As %Boolean = 0)
{
#define addLine(%text) if ResourceName'="" { do $system.Event.Signal(ResourceName, %text) } else { write !,%text}

	set ext=$zcvt($p(InternalName, ".", *),"l")
	if ext'="cls" quit $$$OK
	set className=$p(InternalName, ".", 1, *-1)
	set classFileName = className _ ".cls"

    set binPath=$system.Util.BinaryDirectory()_"/sonarlint/bin/"
    set sonarlint=##class(%File).NormalizeFilename("sonarlint", binPath)

    set tempDir=$e(##class(%File).TempFilename("tmp"), 1, *-4)
    if '##class(%File).CreateDirectoryChain(tempDir) {
    	quit $$$ERROR(5001, "")
    }
    set tempDir=##class(%File).NormalizeDirectory(tempDir)
    set fileName=##class(%File).NormalizeFilename(classFileName, tempDir)
    
    set tSC=##class(%Compiler.UDL.TextServices).GetTextAsFile(, className, fileName)
    if $$$ISERR(tSC) quit tSC
    
    set cmd="cd "_tempDir_" && " 
    set cmd=cmd_sonarlint
    if $zversion(1)=1 set cmd=cmd_".bat"
    
    set cmd=cmd_" -D sqca.workDir="_tempDir_" "
    
    set cmd=cmd_" -X "
    
    set tempSonarDir = ##class(%File).NormalizeDirectory(".sonarlint", tempDir)
    do ##class(%File).CreateDirectory(tempSonarDir)
    set reportFile=##class(%File).NormalizeFilename("sonarReport.xml", tempSonarDir)
    set cmd=cmd_" --xml-report "_reportFile

    set logFile=tempSonarDir_"sonarlint.log"
    set cmd=cmd_" > "_logFile
    
    set sc=$zf(-1, cmd)
    
    set pat=##class(%Regex.Matcher).%New("^(\w+): ")
    if ##class(%File).Exists(logFile) {
    	set fs=##class(%Stream.FileCharacter).%New()
    	set fs.Filename=logFile
    	while 'fs.AtEnd {
    		set line=fs.ReadLine()
	    	set pat.Text=line
	    	if ('pat.Locate())||(pat.Group(1)'="ERROR") {
	    		continue
	    	}
    		$$$addLine(line)
    	}
    }

    set severityList=$lb("blocker","critical","major","minor","info")
	do {
		set tSC=##class(%XML.XPATH.Document).CreateFromFile(reportFile,.tDoc)
		If $$$ISERR(tSC) Quit
		
		set tSC=tDoc.EvaluateExpression("/sonarlintreport/files/file[@name="""_classFileName_"""]/issues", "issue", .tResults)
		If $$$ISERR(tSC) Quit
		
		for i=1:1:tResults.Count() {
			set tRes=tResults.GetAt(i)
			
			while tRes.Read() {
				set (severity,key,name,line)=""
				if tRes.NodeType="element" {
					if tRes.MoveToAttributeName("severity") { set severity=tRes.Value }
					if tRes.MoveToAttributeName("key") { set key=tRes.Value }
					if tRes.MoveToAttributeName("name") { set name=tRes.Value }
					if tRes.MoveToAttributeName("line") { set line=tRes.Value }
					if tRes.MoveToAttributeName("offset") { set offset=tRes.Value }
					
					set severityLevel=$lf(severityList, severity)
					if $i(issues(severityLevel)),$i(issues(severityLevel,key))
					set issues(severityLevel,key,"name")=name
					set issues(severityLevel,key,"lines",line)=offset
				}
			}
		}
		
	} while (0)
	If $$$ISERR(tSC) {
		$$$addLine($system.Status.GetErrorText(tSC))
	}
	
	set tSC=##class(%Compiler.UDL.TextServices).GetTextAsArray(,className,.linesOfClass)
	
	set severityLevel=""
	for {
		set severityLevel=$order(issues(severityLevel), 1, count)
		quit:severityLevel=""
		
		$$$addLine($j(count,5)_" "_$lg(severityList, severityLevel))
		
		set key=""
		for {
			set key=$o(issues(severityLevel, key), 1, byKeyCount)
			quit:key=""
			
			set name=issues(severityLevel, key, "name")
			
			$$$addLine($j(byKeyCount,8)_" "_name)
			
			if (forStudio) {
				set line=""
				for {
					set line=$order(issues(severityLevel, key, "lines", line), 1, offset)
					quit:line=""
					
					$$$addLine(classFileName_"(+"_line_"): "_$get(linesOfClass(line)))
				}
			}
		}
	}
		
	set tSC=##class(%File).RemoveDirectoryTree(tempDir)
	quit $$$OK
}

}
