module Main exposing (..)

import Dict
import Html exposing (..)
import Model exposing (Model, initialModel)
import Ports
import Time
import Update exposing (update, Msg(..))
import View exposing (view)
import WebSocket


main : Program Never Model Msg
main =
    Html.program
        { init = init
        , view = view
        , update = update
        , subscriptions = subscriptions
        }


init : ( Model, Cmd Msg )
init =
    ( initialModel, Cmd.none )


subscriptions : Model -> Sub Msg
subscriptions model =
    let
        -- Establish all of our open websocket connections
        recvWs =
            model.serverInfo
                |> Dict.toList
                |> List.map
                    (\( serverName, info ) ->
                        WebSocket.listen info.socket
                            (\n -> ReceiveRawLine serverName n)
                    )
    in
        Sub.batch
            ([ Ports.onIrcMessage ReceiveLine
             , Ports.onIrcConnected ConnectIrc
             , Ports.addSavedServer AddServer
             , Time.every Time.second Tick
             ]
                ++ recvWs
            )
