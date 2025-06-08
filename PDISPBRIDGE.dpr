program PDISPBRIDGE;

uses
  SvcMgr,
  UIGASBRIDGE in 'UIGASBRIDGE.pas' {ogcvdispensarios_bridge: TService};

{$R *.RES}

begin
  Application.Initialize;
  Application.CreateForm(Togcvdispensarios_bridge, ogcvdispensarios_bridge);
  Application.Run;
end.
