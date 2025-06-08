unit UIGASBRIDGE;

interface

uses
  Windows, Messages, SysUtils, Classes, Graphics, Controls, SvcMgr, Dialogs,
  ScktComp, IniFiles, ULIBGRAL, DB, RxMemDS, uLkJSON, CRCs, ExtCtrls, SyncObjs;

type
  Togcvdispensarios_bridge = class(TService)
    SSocketOG: TServerSocket;
    SSocketPDisp: TServerSocket;
    procedure ServiceExecute(Sender: TService);
    procedure SSocketOGClientRead(Sender: TObject;
      Socket: TCustomWinSocket);
    procedure SSocketPDispClientRead(Sender: TObject;
      Socket: TCustomWinSocket);
  private
    { Private declarations }
  public
    ListaLogOG:TStringList;
    ListaLogPDisp:TStringList;
    rutaLog:string;
    folio:Integer;
    rootJSON: TlkJSONobject;
    horaAct: TDateTime;
    function GetServiceController: TServiceController; override;
    procedure AddPeticion(valor:string; comando:string; socket:TCustomWinSocket);
    procedure AgregaLogOG(lin: string);
    procedure AgregaLogPDisp(lin: string);
    function CRC16(Data: string): string;
    procedure ResponderOG(resp: string; socket:TCustomWinSocket);
    function ObtenerEstado:string;
    function ObtenerEstadoPosiciones(xpos:Integer):string;
    function ObtenerTranPosCarga(xpos:Integer):string;
    procedure GuardaLogOG;
    procedure GuardaLogPDisp;
    procedure ProcesaRespuestasJSON(const ATexto: string);
    { Public declarations }
  end;

type TMetodos = (STATUS_e, TRANSACTION_e, TOTALS_e, STATE_e);

type
  TPeticion = class
    Folio    : Integer;
    Comando  : string;
    Peticion : string;
    Tries    : Integer;
    CliSock  : TCustomWinSocket;
  end;

  TPeticionQueue = class
  private
    FList : TList;
    FCS   : TRTLCriticalSection;
  public
    ListaPeticiones : TPeticionQueue;
    constructor Create;
    destructor  Destroy; override;

    procedure  Push(APeticion: TPeticion);
    function  TryPeek(out APeticion: TPeticion;
                      MaxTries: Integer = 2): Boolean;
    function   IsEmpty: Boolean;
    function TryLocateByFolio(AFol: Integer; out APet: TPeticion): Boolean;
    procedure Remove(APeticion: TPeticion; AFree: Boolean = True);
  end;

var
  ogcvdispensarios_bridge: Togcvdispensarios_bridge;
  ListaPeticiones:TPeticionQueue;

implementation

uses TypInfo, StrUtils, DateUtils;

{$R *.DFM}

constructor TPeticionQueue.Create;
begin
  inherited Create;
  FList := TList.Create;
  InitializeCriticalSection(FCS);
end;

destructor TPeticionQueue.Destroy;
begin
  DeleteCriticalSection(FCS);
  FList.Free;
  inherited;
end;

procedure TPeticionQueue.Push(APeticion: TPeticion);
begin
  EnterCriticalSection(FCS);
  try
    FList.Add(APeticion);
  finally
    LeaveCriticalSection(FCS);
  end;
end;

function TPeticionQueue.TryPeek(out APeticion: TPeticion;
                                MaxTries: Integer = 2): Boolean;
var
  Tmp : TPeticion;
begin
  APeticion := nil;
  EnterCriticalSection(FCS);
  try
    while FList.Count > 0 do
    begin
      Tmp := TPeticion(FList[0]);
      Inc(Tmp.Tries);

      if Tmp.Tries >= MaxTries then
      begin
        FList.Delete(0);
        Tmp.Free;
        Continue;
      end;

      APeticion := Tmp;
      Result    := True;
      Exit;
    end;

    Result := False;
  finally
    LeaveCriticalSection(FCS);
  end;
end;

function TPeticionQueue.TryLocateByFolio(AFol: Integer; out APet: TPeticion): Boolean;
var
  i: Integer;
begin
  APet := nil;
  EnterCriticalSection(FCS);
  try
    for i := 0 to FList.Count - 1 do
      if TPeticion(FList[i]).Folio = AFol then
      begin
        APet  := TPeticion(FList[i]);
        Result := True;
        Exit;
      end;
    Result := False;
  finally
    LeaveCriticalSection(FCS);
  end;
end;

function TPeticionQueue.IsEmpty: Boolean;
begin
  EnterCriticalSection(FCS);
  try
    Result := FList.Count = 0;
  finally
    LeaveCriticalSection(FCS);
  end;
end;

procedure TPeticionQueue.Remove(APeticion: TPeticion; AFree: Boolean = True);
var
  Idx : Integer;
begin
  if APeticion = nil then
    Exit;

  EnterCriticalSection(FCS);
  try
    Idx := FList.IndexOf(APeticion);
    if Idx <> -1 then
    begin
      FList.Delete(Idx);
      if AFree then
        APeticion.Free;
    end;
  finally
    LeaveCriticalSection(FCS);
  end;
end;

procedure ServiceController(CtrlCode: DWord); stdcall;
begin
  ogcvdispensarios_bridge.Controller(CtrlCode);
end;

function Togcvdispensarios_bridge.GetServiceController: TServiceController;
begin
  Result := ServiceController;
end;

procedure Togcvdispensarios_bridge.ServiceExecute(Sender: TService);
var
  config:TIniFile;
begin
  try
    config:= TIniFile.Create(ExtractFilePath(ParamStr(0)) +'PDispBridge.ini');
    rutaLog:=config.ReadString('CONF','RutaLog','C:\ImagenCo');
    SSocketOG.Port:=config.ReadInteger('CONF','PuertoOG',1001);
    SSocketPDisp.Port:=config.ReadInteger('CONF','PuertoPDisp',1003);
    ListaLogOG:=TStringList.Create;
    ListaLogPDisp:=TStringList.Create;
    rootJSON:=TlkJSONObject.Create;
    ListaPeticiones:=TPeticionQueue.Create;

    SSocketOG.Active:=True;
    SSocketPDisp.Active:=True;

    while not Terminated do
      ServiceThread.ProcessRequests(True);
    SSocketOG.Active := False;
    SSocketPDisp.Active := False;
  except
    on e:exception do begin
      ListaLogOG.Add('Error al iniciar servicio: '+e.Message);
      ListaLogOG.SaveToFile(rutaLog+'\LogOG'+FiltraStrNum(FechaHoraToStr(Now))+'.txt');
    end;
  end;
end;

procedure Togcvdispensarios_bridge.SSocketOGClientRead(
  Sender: TObject; Socket: TCustomWinSocket);
  var
    mensaje,comando,parametro, checksum:string;
    i:Integer;
    chks_valido:Boolean;
begin
  try
    mensaje:=Socket.ReceiveText;
    AgregaLogOG('R '+mensaje);

    for i:=1 to Length(mensaje) do begin
      if mensaje[i]=#2 then begin
        mensaje:=Copy(mensaje,i+1,Length(mensaje));
        Break;
      end;
    end;
    for i:=Length(mensaje) downto 1 do begin
      if mensaje[i]=#3 then begin
        checksum:=Copy(mensaje,i+1,4);
        mensaje:=Copy(mensaje,1,i-1);
        Break;
      end;
    end;
    chks_valido:=checksum=CRC16(mensaje);
    if mensaje[1]='|' then
      Delete(mensaje,1,1);
    if mensaje[Length(mensaje)]='|' then
      Delete(mensaje,Length(mensaje),1);
    if NoElemStrSep(mensaje,'|')>=2 then begin
      if UpperCase(ExtraeElemStrSep(mensaje,1,'|'))<>'DISPENSERS' then begin
        ResponderOG('DISPENSERS|False|Este servicio solo procesa solicitudes de dispensarios|',Socket);
        Exit;
      end;

      comando:=UpperCase(ExtraeElemStrSep(mensaje,2,'|'));

      if not chks_valido then begin
        ResponderOG('DISPENSERS|'+comando+'|False|Checksum invalido|',Socket);
        Exit;
      end;

      AddPeticion(mensaje,comando,Socket);
    end
    else
      ResponderOG('DISPENSERS|'+mensaje+'|False|Comando desconocido|',Socket);
  except
    on e:Exception do begin
      AgregaLogOG('Error SSocketOGClientRead: '+e.Message);
      ListaLogOG.SaveToFile(rutaLog+'\LogOG'+FiltraStrNum(FechaHoraToStr(Now))+'.txt');
      ResponderOG('DISPENSERS|'+comando+'|False|'+e.Message+'|',Socket);
    end;
  end;
end;

procedure Togcvdispensarios_bridge.AddPeticion(valor: string; comando:string; socket:TCustomWinSocket);
var
  metodoEnum:TMetodos;
  p:TPeticion;
begin
  metodoEnum := TMetodos(GetEnumValue(TypeInfo(TMetodos), comando+'_e'));

  case metodoEnum of
    STATE_e:
      ResponderOG(ObtenerEstado,socket);
    STATUS_e:
      ResponderOG(ObtenerEstadoPosiciones(StrToIntDef(ExtraeElemStrSep(valor,3,'|'),0)),socket);
    TRANSACTION_e:
      ResponderOG(ObtenerTranPosCarga(StrToIntDef(ExtraeElemStrSep(valor,3,'|'),0)),socket);
  else
    inc(folio);
    if folio>999 then
      folio:=1;

    p:=TPeticion.Create;
    p.Folio:=folio;
    p.Comando:=comando;
    p.Peticion:=valor;
    p.CliSock:=socket;
    ListaPeticiones.Push(p);
    if comando='TRACE' then begin
      GuardaLogOG;
      GuardaLogPDisp;
    end;
  end;
end;

procedure Togcvdispensarios_bridge.AgregaLogOG(lin: string);
var lin2:string;
    i:integer;
begin
  lin2:=FechaHoraExtToStr(now)+' ';
  for i:=1 to length(lin) do
    case lin[i] of
      #1:lin2:=lin2+'<SOH>';
      #2:lin2:=lin2+'<STX>';
      #3:lin2:=lin2+'<ETX>';
      #6:lin2:=lin2+'<ACK>';
      #21:lin2:=lin2+'<NAK>';
      #23:lin2:=lin2+'<ETB>';
      else lin2:=lin2+lin[i];
    end;
  while ListaLogOG.Count>10000 do
    ListaLogOG.Delete(0);
  ListaLogOG.Add(lin2);
end;

function Togcvdispensarios_bridge.CRC16(Data: string): string;
var
  aCrc:TCRC;
  pin : Pointer;
  insize:Cardinal;
begin
  insize:=Length(Data);
  pin:=@Data[1];
  aCrc:=TCRC.Create(CRC16Desc);
  aCrc.CalcBlock(pin,insize);
  Result:=UpperCase(IntToHex(aCrc.Finish,4));
  aCrc.Destroy;
end;

procedure Togcvdispensarios_bridge.ResponderOG(resp: string; socket:TCustomWinSocket);
begin
  try
    AgregaLogOG('E '+#1#2+resp+#3+CRC16(resp)+#23);
    socket.SendText(#1#2+resp+#3+CRC16(resp)+#23);
  except
    on e:Exception do begin
      AgregaLogOG('Error ResponderOG: '+e.Message);
      ListaLogOG.SaveToFile(rutaLog+'\LogOG'+FiltraStrNum(FechaHoraToStr(Now))+'.txt');
    end;
  end;
end;

function Togcvdispensarios_bridge.ObtenerEstado:String;
var
  n:TlkJSONbase;
begin
  if rootJSON = nil then
    Exit;

  if SecondsBetween(Now, horaAct)>=2 then begin
    SSocketOG.Active:=False;
    Exit;
  end;

  n:=rootJSON.Field['Estado'];

  if Assigned(n) then
    Result:='DISPENSERS|STATE|True|'+IntToStr(rootJSON.Field['Estado'].Value)+'|'
  else
    Result:='DISPENSERS|STATE|True|-1|';
end;

function Togcvdispensarios_bridge.ObtenerEstadoPosiciones(xpos:Integer):string;
var
  posList     : TlkJSONlist;
  posObj      : TlkJSONobject;
  estadoNode  : TlkJSONbase;
  i           : Integer;
  AEstados    : string;
begin
  try
    if rootJSON = nil then
      Exit;

    posList := rootJSON.Field['PosCarga'] as TlkJSONlist;
    if posList = nil then
      Exit;

    for i := 0 to posList.Count - 1 do
    begin
      posObj := TlkJSONobject(posList.Child[i]);
      if posObj = nil then
        Continue;

      estadoNode := posObj.Field['Estatus'];
      if estadoNode = nil then
        Continue;

      AEstados := AEstados + Trim(estadoNode.Value);
    end;

    if xpos>0 then
      Result:='DISPENSERS|STATUS|True|'+AEstados[xpos]+'|'
    else
      Result:='DISPENSERS|STATUS|True|'+AEstados+'|';
  except
    on e:Exception do begin
      AgregaLogOG('Error ObtenerEstadoPosiciones :'+e.Message);
      GuardaLogOG;
    end;
  end;
end;

function Togcvdispensarios_bridge.ObtenerTranPosCarga(xpos: Integer):string;
var
  posList     : TlkJSONlist;
  posObj      : TlkJSONobject;
  i           : Integer;

begin
  if xpos<=0 then
    Exit;

  if rootJSON = nil then
    Exit;

  posList := rootJSON.Field['PosCarga'] as TlkJSONlist;
  if posList = nil then
    Exit;

  for i := 0 to posList.Count - 1 do
  begin
    posObj := TlkJSONobject(posList.Child[i]);
    if posObj = nil then
      Continue;

    if(posObj.Field['DispenserId'].Value=xpos) then begin
      Result:='DISPENSERS|TRANSACTION|True|'+posObj.Field['HoraOcc'].Value+'|'+IntToStr(posObj.Field['Manguera'].Value)+'|'+IntToStr(posObj.Field['Combustible'].Value)+'|'+
                   FormatFloat('0.000',posObj.Field['Volumen'].Value)+'|'+FormatFloat('0.00',posObj.Field['Precio'].Value)+'|'+FormatFloat('0.00',posObj.Field['Importe'].Value)+'|';
    end
    else
      Continue;
  end;
end;

procedure Togcvdispensarios_bridge.GuardaLogOG;
begin
  ListaLogOG.SaveToFile(rutaLog+'\LogOG'+FiltraStrNum(FechaHoraToStr(Now))+'.txt');
end;

procedure Togcvdispensarios_bridge.SSocketPDispClientRead(Sender: TObject;
  Socket: TCustomWinSocket);
var
  respTxt   : string;
  folioResp : Integer;
  p : TPeticion;
begin
  try
    respTxt := Socket.ReceiveText;
    AgregaLogPDisp('R '+respTxt);
    if not SSocketOG.Active then
      SSocketOG.Active:=True;
    if not AnsiContainsText(respTxt,'PING') then
      ProcesaRespuestasJSON(respTxt);

    if ListaPeticiones.TryPeek(p) then begin
      AgregaLogPDisp('E '+IntToStr(p.Folio)+'|'+p.Peticion);
      Socket.SendText(IntToStr(p.Folio)+'|'+p.Peticion);
      Exit;
    end;

    AgregaLogPDisp('E 0|NOTHING');
    Socket.SendText('0|NOTHING');
  except
    on e:Exception do begin
      AgregaLogPDisp('Error SSocketPDispClientRead :'+e.Message);
      GuardaLogPDisp;
    end;
  end;
end;

procedure Togcvdispensarios_bridge.AgregaLogPDisp(lin: string);
var lin2:string;
begin
  lin2:=FechaHoraExtToStr(now)+' '+lin;
  while ListaLogPDisp.Count>10000 do
    ListaLogPDisp.Delete(0);
  ListaLogPDisp.Add(lin2);
end;

procedure Togcvdispensarios_bridge.ProcesaRespuestasJSON(
  const ATexto: string);
var
  jArray    : TlkJSONbase;
  jItem     : TlkJSONbase;
  i, Folio  : Integer;
  Resultado : string;
  p : TPeticion;
begin
  if Assigned(rootJSON) then
    rootJSON.Free;
  rootJSON := TlkJSONobject(TlkJSON.ParseText(ATexto));
  horaAct:=Now;
  try
    jArray := rootJSON.Field['Peticiones'];
    if not (jArray is TlkJSONlist) then
      Exit;

    for i := 0 to jArray.Count - 1 do
    begin
      jItem := jArray.Child[i];

      Folio     := jItem.Field['Folio'].Value;
      Resultado := jItem.Field['Resultado'].Value;

      if ListaPeticiones.TryLocateByFolio(Folio, p) then
      begin
        ResponderOG('DISPENSERS|' + p.Comando + '|' + Resultado, p.CliSock);
        ListaPeticiones.Remove(p);
      end;
    end;
  except
    on e:Exception do begin
      AgregaLogPDisp('Error ProcesaRespuestasJSON :'+e.Message);
      GuardaLogPDisp;
    end;
  end;
end;

procedure Togcvdispensarios_bridge.GuardaLogPDisp;
begin
  ListaLogPDisp.SaveToFile(rutaLog+'\LogPDisp'+FiltraStrNum(FechaHoraToStr(Now))+'.txt');
end;

end.
