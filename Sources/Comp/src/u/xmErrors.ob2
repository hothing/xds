(** Copyright (c) 1994,97 XDS Ltd, Russia. All Rights Reserved. *)
(** o2/m2 development system v2.0 *)
(** Standard implementation of "Errors" and "Info" managers *)
<* IF ~ DEFINED(STATANALYSIS) THEN *> <* NEW STATANALYSIS- *> <* END *>
<*+ O2ADDKWD *>
MODULE xmErrors;

IMPORT
   SYSTEM
  ,xcStr
  ,xfs:=xiFiles
  ,env:=xiEnv
  ,pcK
  ,Strings
  ,DStrings
  ,cc:=CharClass
  ,StdChans
  ,IOChan
  ,TextIO
  ,expt := EXCEPTIONS
  ,COMPILER
  ,TimeConv
  ,Printf
<* IF USE_CLIBS THEN *> ,x2cLib
<* ELSE *>              ,SysClock
<* END *>
<* IF pcvis THEN *> ,pcVis <* END *>
  ;

CONST (* ERRFMT *)
  default =
    '"(%s",file;' +
    '" %d",line; ",%d",column;' +
    '") [%.1s] ",mode; "%s\n",errmsg;';

  plain = "'%s',errmsg;";

TYPE
  Info = POINTER TO InfoDesc;
  InfoDesc = RECORD (env.InfoDesc)
    starttime: SYSTEM.CARD32; (* time *)
    totaltime: SYSTEM.CARD32;
    errs     : LONGINT;
    warns    : LONGINT;
    files    : LONGINT;
    total    : LONGINT; (* lines *)
  END;

  Node = POINTER TO NodeDesc;
  NodeDesc = RECORD
    msg : env.String;
    fnm : env.String;
    l,c : LONGINT;
    type: CHAR;
    next: Node;
  END;

  Errors = POINTER TO ErrorsDesc;
  ErrorsDesc = RECORD (env.ErrorsDesc)
    msg     : env.String; (* MX.MSG file                          *)
    fmt     : env.String; (* ERRFMT equation value                *)
    node    : Node;       (* sorted list of error messages        *)
    errlim  : LONGINT;    (* ERRLIM equation value                *)
    trap    : BOOLEAN;    (* exception trap is available          *)
    errno   : INTEGER;
    plainmsg : env.String; (* last generated by PrepareMsg message *)
  END;

VAR source: expt.ExceptionSource;

PROCEDURE ShowLine(s-: ARRAY OF CHAR; c: LONGINT);
(* print source text line, truncate if it is needed *)
  CONST max = 72;
  VAR buf: ARRAY max+1 OF CHAR; p: LONGINT;
BEGIN
  IF c < max THEN p:=0;
  ELSIF LEN(s) - c >= max THEN p:=c - (max DIV 2);
  ELSE p:=LEN(s)-max
  END;
  Strings.Extract(s,SHORT(p),max-1,buf);
  Strings.Insert('$',c-SHORT(p),buf);
  IF p > 0 THEN env.info.print('...') END;
  env.info.print('%s',buf);
  IF p + max < LEN(s) THEN env.info.print('...') END;
  env.info.print('\n');
END ShowLine;

PROCEDURE ReadLine(f: xfs.TextFile; line,l: LONGINT; VAR s: env.String);
  VAR buf: ARRAY 256 OF CHAR;
BEGIN
  s:=NIL;
  WHILE line < l DO
    f.ReadString(buf);
    IF f.readRes = xfs.endOfInput THEN RETURN
    ELSIF f.readRes = xfs.endOfLine THEN INC(line);
    END;
  END;
  LOOP
    f.ReadString(buf);
    IF f.readRes = xfs.endOfInput THEN RETURN
    ELSIF f.readRes = xfs.endOfLine THEN EXIT
    END;
    DStrings.Append(buf,s);
  END;
END ReadLine;

PROCEDURE ShowErrors(e: Errors);
  VAR n: Node; f: xfs.TextFile;
     lineno: LONGINT; line,fnm: env.String;
BEGIN
  IF env.shell.Active() THEN RETURN END;
  n:=e.node; e.node:=NIL; f:=NIL; fnm:=NIL; lineno:=0; line:=NIL;
  WHILE n#NIL DO
    IF fnm#n.fnm THEN
      IF f#NIL THEN f.Close END;
      f:=NIL; fnm:=NIL;
      IF n.fnm#NIL THEN
        xfs.text.Open(n.fnm^,FALSE);
        IF xfs.text.file#NIL THEN
          f:=xfs.text.file(xfs.TextFile);
          fnm:=n.fnm;
        END;
      END;
      lineno:=0; line:=NIL;
    END;
    env.info.print("%s",n.msg^);
    IF (f#NIL) & (n.l>=0) THEN
      IF lineno <= n.l THEN ReadLine(f,lineno,n.l,line); lineno:=n.l+1 END;
      IF line#NIL THEN ShowLine(line^,n.c) END;
    END;
    n:=n.next;
  END;
  IF f#NIL THEN f.Close END;
END ShowErrors;

(*----------------------------------------------------------------*)

PROCEDURE (e: Errors) Execute(proc: env.PROC; VAR exc: BOOLEAN);

  PROCEDURE exec;
    VAR s: env.MESSAGE;
  BEGIN
    exc:=FALSE;
    e.trap:=TRUE;
    proc;
    e.trap:=FALSE;
    ShowErrors(e);
  EXCEPT
    exc:=TRUE;
    e.trap:=FALSE;
    ShowErrors(e);
    IF ~expt.IsCurrentSource(source) THEN 
      expt.GetMessage(s);
      env.errors(Errors).errno := 450;
      env.errors.PrintMsg(env.null_pos, 'f', "compilation aborted: %s", s);
    ELSE
      RETURN
    END;
  END exec;

  PROCEDURE exec_debug;
  BEGIN
    exc:=FALSE;
    e.trap:=TRUE;
    proc;
    e.trap:=FALSE;
    ShowErrors(e);
  END exec_debug;

BEGIN
  IF env.config.Option("XDEBUG") THEN exec_debug ELSE exec END;
END Execute;

(*----------------------------------------------------------------*)

PROCEDURE Skip(s-: ARRAY OF CHAR; VAR p: INTEGER);
BEGIN
  WHILE (p < LEN(s)) & cc.IsWhiteSpace(s[p]) DO INC(p) END;
END Skip;

PROCEDURE Argument(s-: ARRAY OF CHAR;
              VAR i: INTEGER;
              VAR errpos: LONGINT;
              VAR f,a: ARRAY OF CHAR);
  VAR ch: CHAR; n,p: INTEGER;
BEGIN
  f[0]:=0X;
  Skip(s,i);
  ch:=s[i];
  IF (ch="'") OR (ch='"') THEN
    p:=i+1;
    REPEAT INC(i) UNTIL (s[i]=0X) OR (s[i]=ch);
    IF s[i]=0X THEN errpos:=i; RETURN END;
    Strings.Extract(s,p,i-p,f);
    INC(i);
  ELSE errpos:=i; RETURN
  END;
  Skip(s,i);
  n:=0;
  IF s[i]=',' THEN
    INC(i);
    ch:=s[i];
    WHILE (ch#0C) & (cc.IsLetter(ch) OR cc.IsNumeric(ch)) DO
      IF n < LEN(a)-1 THEN a[n]:=ch; INC(n) END;
      INC(i);
      ch:=s[i];
    END;
  END;
  a[n]:=0C;
  Skip(s,i);
  IF s[i]=';' THEN INC(i)
  ELSIF s[i]#0X THEN errpos:=i
  END;
END Argument;

PROCEDURE PrepareMsg(VAR res : env.String;
                 errfmt-,msg-: ARRAY OF CHAR;
                         type: CHAR;
                          fnm: env.String;
                          l,c: LONGINT;
                        errno: INTEGER;
                   VAR errpos: LONGINT);
  VAR
    i: INTEGER;
    len: LONGINT;
    pn: env.String;
    a: ARRAY 16 OF CHAR;
    f: ARRAY 64 OF CHAR;
    x: ARRAY 1024 OF CHAR;
BEGIN
  errpos:=-1;
  DStrings.Assign("",res);
  len:=LENGTH(errfmt);
  IF len = 0 THEN errpos:=0; RETURN END;
  i:=0;
  WHILE i < len DO
    Skip(errfmt,i);
    Argument(errfmt,i,errpos,f,a);
    IF errpos >=0 THEN
      RETURN
    ELSE
      Strings.Capitalize(a);
      x:='';
      IF    a[0]=0X      THEN xcStr.prn_txt(x,f)
      ELSIF a="LINE"     THEN xcStr.prn_txt(x,f,l+1)
      ELSIF a="COLUMN"   THEN xcStr.prn_txt(x,f,c+1)
      ELSIF a="ERRNO"    THEN xcStr.prn_txt(x,f,errno)
      ELSIF a="ERRMSG"   THEN xcStr.prn_txt(x,f,msg)
      ELSIF a="FILE"     THEN
        IF fnm#NIL THEN
          xfs.sys.ConvertToHost(fnm^,pn);
          xcStr.prn_txt(x,f,pn^)
        ELSE
          xcStr.prn_txt(x,f,"***")
        END;
      ELSIF a="MODULE"   THEN
        IF env.info.module=NIL THEN xcStr.prn_txt(x,f,"***");
        ELSE xcStr.prn_txt(x,f,env.info.module^)
        END;
      ELSIF a="MODE"     THEN
        IF    type='w' THEN xcStr.prn_txt(x,f,"WARNING")
        ELSIF type='e' THEN xcStr.prn_txt(x,f,"ERROR")
        ELSIF type='s' THEN xcStr.prn_txt(x,f,"ERROR")
        ELSIF type='f' THEN xcStr.prn_txt(x,f,"FAULT")
        ELSE ASSERT(FALSE);
        END;
      ELSIF a="LANGUAGE" THEN
        IF env.info.language=env.flag_o2 THEN xcStr.prn_txt(x,f,"Oberon-2")
        ELSE xcStr.prn_txt(x,f,"Modula-2")
        END;
      ELSIF a="UTILITY" THEN
        env.args.ProgramName(pn); xcStr.prn_txt(x,f,pn^)
      ELSE
        errpos:=i;
        RETURN
      END;
      DStrings.Append(x,res);
    END;
  END;
END PrepareMsg;

PROCEDURE CheckFormat(e: Errors);
  VAR bump: env.String; errpos: LONGINT;
BEGIN
  env.config.Equation("ERRFMT",e.fmt);
  IF e.fmt#NIL THEN
    PrepareMsg(bump,e.fmt^,'','w',NIL,0,0,0,errpos);
    IF errpos >= 0 THEN
      env.errors.Message(431,errpos);
      e.fmt:=NIL;
    END;
  END;
  IF e.fmt=NIL THEN DStrings.Assign(default,e.fmt) END;
END CheckFormat;

(*----------------------------------------------------------------*)

PROCEDURE Insert(e: Errors; fnm: env.String; l,c: LONGINT;
                        type: CHAR; VAR n: Node; msg:env.String);

  PROCEDURE lss(x: Node): BOOLEAN;
  BEGIN
    IF x=NIL THEN RETURN FALSE END;
    IF fnm=NIL THEN RETURN TRUE END;
    IF x.fnm=NIL THEN RETURN FALSE END;
    IF x.fnm^<fnm^ THEN RETURN TRUE END;
    IF x.fnm^>fnm^ THEN RETURN FALSE END;
    RETURN (x.l<l) OR ((x.l=l) & (x.c<c));
  END lss;

  VAR x,p: Node;
BEGIN
  x:=e.node; p:=NIL;
  WHILE lss(x) DO p:=x; x:=x.next END;
  IF (x#NIL) & (x.fnm#NIL) & (fnm#NIL) & (x.fnm^=fnm^) &
     (x.l=l) & (x.c=c) & (x.type=type) & (x.msg^=msg^)
  THEN
    RETURN;
  END;
  NEW(n);
  n.fnm:=fnm; n.l:=l; n.c:=c; n.type:=type; n.msg := msg;
  IF p=NIL THEN n.next:=e.node; e.node:=n
  ELSE n.next:=x; p.next:=n
  END;
END Insert;

PROCEDURE ModifyCounters(e: Errors; type: CHAR);
  VAR buf: env.MESSAGE;
BEGIN
  IF type='e' THEN
    INC(e.err_cnt);
    IF e.err_cnt > e.errlim THEN
      e.GetMsg(437,buf);
      e.PrintMsg(env.null_pos,'f',buf);
    END;
  ELSIF type='w' THEN INC(e.wrn_cnt);
  ELSIF type='f' THEN INC(e.err_cnt);
  ELSIF type='s' THEN INC(e.err_cnt); e.soft_fault:=TRUE;
  ELSE ASSERT((type='v') OR (type='m'));
  END;
END ModifyCounters;

PROCEDURE (e: Errors) GetLastMsg(VAR s : env.String);
BEGIN
  s := e.plainmsg
END GetLastMsg;

PROCEDURE (e: Errors) PrintMsg(pos: env.TPOS;
                              type: CHAR;
                              fmt-: ARRAY OF CHAR;
                             SEQ x: SYSTEM.BYTE);
  VAR
    n: Node;
    errpos,l,c: LONGINT;
    str,fnm,fname: env.String;
    el: BOOLEAN;
    ch: CHAR;
    msg: env.String;
BEGIN
  n:=NIL;
  e.plainmsg := NIL;
  IF type='m' THEN
    env.info.print(fmt,x); env.info.print("\n");
  ELSE
    pos.unpack(fnm,l,c);
    xcStr.dprn_txt(str,fmt,x);
    IF env.shell.Active() THEN
      CASE type OF
      | 'w': ch := env.MSG_WARNING;
      | 'e',
        's': ch := env.MSG_ERROR;
      | 'f': ch := env.MSG_SEVERE;
      | 'v': ch := env.MSG_SEVERE;
      END;
      IF fnm = NIL THEN
        env.shell.Error(ch,e.errno,c,l,'',str^);
      ELSE
        xfs.sys.ConvertToHost(fnm^,fname);
        env.shell.Error(ch,e.errno,c,l,fname^,str^);
      END;
      ModifyCounters(e,type);
    ELSIF type = 'v' THEN (* the same as 'm' for non-shell *)
      env.info.print(fmt,x); env.info.print("\n");
    ELSE
      IF e.fmt=NIL THEN CheckFormat(e) END;
      PrepareMsg(msg, e.fmt^,str^,type,fnm,l,c,e.errno,errpos);
      Insert(e,fnm,l,c,type,n,msg);
      IF n#NIL THEN
        PrepareMsg(e.plainmsg,plain, str^,type,fnm,l,c,e.errno,errpos);
        ModifyCounters(e,type);
      END;
    END;
  END;
  e.errno:=0;
  IF ~ e.trap THEN ShowErrors(e) END;
  env.config.Equation("ERRORLEVEL",str);
  el:=FALSE;
  IF str#NIL THEN
    l:=0;
    WHILE str[l]#0X DO
      el:=el OR (CAP(type)=CAP(str[l]));
      INC(l);
    END;
  END;
  IF (type='f') OR (type='s') OR el THEN
    IF e.trap THEN
      ShowErrors(e);
      expt.RAISE(source,0,"XDEBUG option is ON !");
    ELSE
      HALT(3);
    END;
  END;
END PrintMsg;

PROCEDURE (e: Errors) Warning(ps: env.TPOS; no: INTEGER; SEQ x: SYSTEM.BYTE);
  VAR woff,won,werr: ARRAY 16 OF CHAR;
BEGIN
  xcStr.prn_txt(woff,"WOFF%d",no);
  xcStr.prn_txt(won,"WON%d",no);
  xcStr.prn_txt(werr,"WERR%d",no);
  IF env.config.OptionAt(ps,"WERR") OR env.config.OptionAt(ps,werr) THEN
    e.Error(ps,no,x)
  ELSIF (NOT env.config.OptionAt(ps,"WOFF") OR env.config.OptionAt(ps,won)) AND
    NOT env.config.OptionAt(ps,woff)
  THEN
    e.Warning^(ps,no,x)
  ELSE
    e.plainmsg := NIL;
  END;
END Warning;

(*----------------------------------------------------------------*)

PROCEDURE Read(VAR msg: xfs.String);
  VAR f: xfs.TextFile; fn,s: xfs.String; len: LONGINT;
      buf: ARRAY 512 (*ok*) OF CHAR;
  VAR _break_ : ARRAY 2 OF CHAR;
BEGIN
  msg:=NIL;
  xfs.sys.SysLookup("msg",fn);

  _break_[0]:= 1X;
  _break_[1]:= 0X;
  xfs.text.Open(fn^,FALSE);
  IF xfs.text.file#NIL THEN
    f:=xfs.text.file(xfs.TextFile);
    len:=f.Length();
    NEW(s,len+1024);
    s[0]:= 1X;
    s[1]:= 0X;
    LOOP
      LOOP
        f.ReadString(buf);
        IF f.readRes # xfs.allRight THEN EXIT END;
        DStrings.Append(buf, s);
      END;
      DStrings.Append(_break_, s);
      IF f.readRes = xfs.endOfInput THEN EXIT END;
    END;
    msg:=s;
    RETURN;
  END;

  NEW(s,1); s[0]:=0X; msg:=s;
  env.info.print("Can't read message file '%s'.\n",fn^);
END Read;

(*

Old version of Read procedure.

PROCEDURE Read(VAR msg: xfs.String);
  VAR f: xfs.RawFile; fn,s: xfs.String; len: LONGINT;
BEGIN
  msg:=NIL;
  xfs.sys.SysLookup("msg",fn);
  xfs.raw.Open(fn^,FALSE);
  IF xfs.raw.file#NIL THEN
    f:=xfs.raw.file(xfs.RawFile);
    len:=f.Length();
    NEW(s,len+1);
    f.ReadBlock(s^,0,len);
    IF f.readRes=xfs.allRight THEN s[len]:=0X; msg:=s; RETURN END;
  END;
  NEW(s,1); s[0]:=0X; msg:=s;
  env.info.print("Can't read message file '%s'.\n",fn^);
END Read;
*)
PROCEDURE SearchMsg(no: INTEGER; VAR s: ARRAY OF CHAR; msg: xfs.String): BOOLEAN;
  VAR i,j,k: LONGINT;
BEGIN
  i:=0;
  WHILE msg[i]#0X DO
    WHILE cc.IsWhiteSpace(msg[i]) DO INC(i) END;
    j:=0;
    WHILE (msg[i]>='0') & (msg[i]<='9') DO
      j:=j*10+(ORD(msg[i])-ORD('0'));
      INC(i);
    END;
    IF j=no THEN
      WHILE cc.IsWhiteSpace(msg[i]) DO INC(i) END;
      k:=0;
      WHILE msg[i]>=' ' DO s[k]:=msg[i]; INC(i); INC(k) END;
      s[k]:=0X;
      RETURN TRUE;
    END;
    WHILE msg[i]>=' ' DO INC(i) END;
    WHILE (msg[i]#0X) & (msg[i]<' ') DO INC(i) END;
  END;
  s[0]:=0X;
  RETURN FALSE;
END SearchMsg;

PROCEDURE (e: Errors) GetMsg(no: INTEGER; VAR s: env.MESSAGE);
BEGIN
  e.errno:=no;
  IF e.msg=NIL THEN Read(e.msg) END;
  IF (e.msg#NIL) & SearchMsg(no,s,e.msg) THEN RETURN END;
  xcStr.prn_txt(s,"Message %d (text is not available)",no);
END GetMsg;

PROCEDURE (e: Errors) Reset;
  VAR s: env.String;
BEGIN
  e.Reset^;
  e.node:=NIL;
  e.trap:=FALSE;
  env.config.Equation("ERRLIM",s);
  IF (s = NIL) OR ~ xcStr.StrToInt(s^,e.errlim) THEN e.errlim:=16 END;
END Reset;

(*----------------------------------------------------------------*)

<* IF USE_CLIBS THEN *>
CONST time = x2cLib.X2C_Clock;
<* ELSE *>
PROCEDURE time(): SYSTEM.CARD32;
  VAR t: SysClock.DateTime;
BEGIN
  SysClock.GetClock(t);
  RETURN ((LONG(ORD(t.hour))*60+LONG(ORD(t.minute)))*60+LONG(ORD(t.second)))*100+
          LONG(ORD(t.fractions))*100 DIV (SysClock.maxSecondParts+1);
END time;
<* END *>

--Return compiler version: "parser_version [code_version]  - build date"
PROCEDURE (i: Info) Version(VAR version: env.String);
VAR t: TimeConv.DateTime;
    str: ARRAY 128 OF CHAR;
BEGIN
  TimeConv.unpack(t, COMPILER.TIMESTAMP);
  Printf.sprintf(str, "XDS %s [%s] - build %02d.%02d.%4d",
              pcK.pars.vers, pcK.code.vers, t.day, t.month, t.year);
  DStrings.Assign(str, version);
END Version;


PROCEDURE (i: Info) Header(lang: env.Lang);
  VAR nm, u, ver: env.String;
BEGIN
  i.language:=lang;
  i.module:=NIL;
  i.lines:=0;
  i.starttime:=time();
  IF i.file=NIL THEN  DStrings.Assign("",nm);
  ELSE xfs.sys.ConvertToHost(i.file^,nm);    --- !!! to print name in host form
  END;
  IF env.dc_header IN env.decor THEN
    i.Version(ver);
    i.print("%s\n", ver^);
    i.print('Compiling "%s"\n', nm^);
    IF env.shell.Active() THEN
      xcStr.dprn_txt(u,"Compiling %s",nm^);
      env.shell.Caption (u^);
    END;
  END;
END Header;

PROCEDURE (i: Info) Report;
  VAR t: SYSTEM.CARD32;
BEGIN
  t:=time()-i.starttime;
  IF t<=0 THEN t:=0 END;
  IF env.dc_report IN env.decor THEN
    IF NOT (env.dc_header IN env.decor) & (i.module#NIL) THEN
      i.print("%-19.19s ",i.module^);
    END;
    IF env.errors.err_cnt=0 THEN i.print("no errors");
    ELSE                         i.print("errors %2d",env.errors.err_cnt);
    END;
    IF env.errors.wrn_cnt=0 THEN i.print(", no warnings");
    ELSE                         i.print(", warnings %2d",env.errors.wrn_cnt);
    END;
    i.print(", lines %4d, time %2d.%02d",i.lines,t DIV 100,t MOD 100);
    IF i.newSF THEN i.print(', new symfile') END;
    IF i.newDF THEN i.print(', (new def)') END;
    i.print('\n');
  END;
  INC(i.files);
  INC(i.errs,LONG(env.errors.err_cnt));
  INC(i.warns,LONG(env.errors.wrn_cnt));
  INC(i.total,i.lines);
  i.totaltime:=i.totaltime+t;
END Report;

PROCEDURE (i: Info) Total;
  VAR sp: SYSTEM.CARD32;
BEGIN
  IF (i.files > 1) OR (i.files = 0) & (env.errors.env_err_cnt > 0) THEN
    sp:=i.totaltime DIV 10;
    IF sp=0 THEN sp:=10000;
    ELSE sp:=VAL(SYSTEM.CARD32,i.total*600) DIV sp;
    END;
    IF env.dc_report IN env.decor THEN
      i.print("-------------------------------------------------------------------\n");
    END;
    i.print("files: %d  errors: %d(%d)  lines %d  time: %d:%02d  speed %d l/m\n",
            i.files,
            i.errs + env.errors.env_err_cnt,
            i.warns,
            i.total,
            (i.totaltime DIV 100) DIV 60,
            (i.totaltime DIV 100) MOD 60,
            sp);
  END;
END Total;

PROCEDURE (i: Info) print(format-: ARRAY OF CHAR; SEQ x: SYSTEM.BYTE);
  VAR msg: env.String; cid : IOChan.ChanId;
BEGIN
  xcStr.dprn_txt(msg,format,x);
  cid := StdChans.OutChan();
  TextIO.WriteString(cid, msg^);
END print;

PROCEDURE (i: Info) compiler_phase(n: INTEGER);
END compiler_phase;


PROCEDURE Init(i: Info);
BEGIN
  i.errs :=0;
  i.warns:=0;
  i.files:=0;
  i.total:=0;
  i.totaltime:=0;
END Init;

(*----------------------------------------------------------------*)

PROCEDURE SetManagers*;
  VAR i: Info; e: Errors;
BEGIN
  NEW(i); i.Reset; Init(i); env.info:=i;
  NEW(e); e.fmt:=NIL; e.msg:=NIL; e.Reset; env.errors:=e;
 <* IF STATANALYSIS THEN *>  -- this assignment should be moved here 
  i.en_b_end:=TRUE;          -- from xiEnv.ob2 for statical analysis tools 
 <* END *> 
END SetManagers;

PROCEDURE FlushStdOut;
  VAR cid : IOChan.ChanId;
BEGIN
  cid := StdChans.OutChan();
  IOChan.Flush(cid);
END FlushStdOut;

BEGIN
  expt.AllocateSource(source);
FINALLY
  FlushStdOut;
END xmErrors.