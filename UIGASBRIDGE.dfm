object ogcvdispensarios_bridge: Togcvdispensarios_bridge
  OldCreateOrder = False
  DisplayName = 'OpenGas Dispensarios Bridge'
  OnExecute = ServiceExecute
  Left = 241
  Top = 125
  Height = 165
  Width = 230
  object SSocketOG: TServerSocket
    Active = False
    Port = 1001
    ServerType = stNonBlocking
    OnClientRead = SSocketOGClientRead
    Left = 35
    Top = 32
  end
  object SSocketPDisp: TServerSocket
    Active = False
    Port = 1002
    ServerType = stNonBlocking
    OnClientRead = SSocketPDispClientRead
    Left = 127
    Top = 32
  end
end
