#!/usr/bin/env python3
"""
Module Docstring
"""

__author__ = "Martin Herfurt (trifinite.org)"
__version__ = "0.1.1"
__license__ = "MIT"

import argparse
import pyfiglet
from datetime import datetime
import re
import asyncio
import time
import sys
import VCSEC_pb2 as VCSEC
import json
import base64
from bleak import BleakClient
from google.protobuf.json_format import MessageToJson
from google.protobuf.text_format import MessageToString

TeslaBeaconUUID =           "74278BDA-B644-4520-8F0C-720EAF059935"
TeslaServiceUUID =          "00000211-B2D1-43F0-9B88-960CEBF8B91E"
TeslaToVehicleCharUUID =    "00000212-B2D1-43F0-9B88-960CEBF8B91E"
TeslaFromVehicleCharUUID =  "00000213-B2D1-43F0-9B88-960CEBF8B91E"
connectTimeout = 10.0


async def main(args):
    global pending
    pending = 0
    #log(3, str(args))
    # check whether mac address is in the right format
    if not re.match("[0-9a-f]{2}([-:]?)[0-9a-f]{2}(\\1[0-9a-f]{2}){4}$", args.device.lower()):
        log(0,"ERROR: invalid MAC address")
        log(0,"Please provide a MAC address in the following format: 1a:2b:3c:4d:5e:6f")
        exit()

    try:
        if(args.stdin):
            log(1,"reading message from stdin")
            messagebytes = bytes.fromhex(sys.stdin.read())
        elif(args.template):
            args.prefix = True
            if args.template == "WHITELIST":
                messagebytes = bytes.fromhex("12040a020805")
            elif args.template == "PUBKEY":
                messagebytes = bytes.fromhex("12040a020803")
        else:
            messagebytes = bytes.fromhex(args.payload)
    
    except Exception as e:
        log(0,"ERROR: invalid payload content")
        log(0,"Please provide your payload as hex string (e.g. 0002aabb)")
        log(3,e)
        exit()

    if (len(messagebytes)==0):
        log(0,"Please provide a payload via --stdin or --payload parameter")


    if args.prefix:
        prefixbytes = getPrefix(len(messagebytes))
        sendmessage = prefixbytes + messagebytes
    else:
        sendmessage = messagebytes

    # establish connection to vehicle
    global client
    client = BleakClient(args.device)
     
    log(1,"Trying to connect to address "+args.device)

    try:
        await client.connect(timeout=connectTimeout)
        await asyncio.sleep(1.0)
    except Exception as e:
        log(0,"ERROR: Failed to connect to vehicle!")
        log(3,e)
        exit()
   
    time.sleep(1)
    log(1,"Connected to address "+args.device)

    # subscribe to characteristic
    log(1,"Subscribing to 'From Vehicle' characteristic")
    try:
        await client.start_notify(TeslaFromVehicleCharUUID, notification_handler)
        await asyncio.sleep(1.0)
    except Exception as e:
        log(0,"ERROR: Failed to subscribe to 'From Vehicle' characteristic!")
        log(3,e)
        exit()

    # write message to characteristic
    log(1,"writing to 'To Vehicle' characteristic")
    await sendToVehicle(sendmessage)
    
    log(1,"wait for response from vehicle");
    
    timeout = float(args.timeout)
    await asyncio.sleep(timeout)

#    while pending>0:
#        await asyncio.sleep(1.0)

    try:
        await client.disconnect()    
    except Exception as e:
        log(0,"ERROR: Failed to connect to vehicle!")
        log(3,e)

async def sendToVehicle(sendmessage):
    try:
        await client.write_gatt_char(TeslaToVehicleCharUUID, sendmessage, False) 
        await asyncio.sleep(2.0)

    except Exception as e:
        log(0,"ERROR: Failed to write to 'To Vehicle' characteristic!")
        log(3,e)
        exit()


def getPrefix(length):
    return length.to_bytes(2, byteorder='big', signed=False)

def output(out):
    if args.output.upper() == "BIN":
        print(out[2 : ])
    elif args.output.upper() == "TXT":
        temp = VCSEC.FromVCSECMessage()
        temp.ParseFromString(out[2 : ])
        print(MessageToString(temp, as_utf8=True))
    elif args.output.upper() == "JSON":
        temp = VCSEC.FromVCSECMessage()
        temp.ParseFromString(out[2 : ])
        print(MessageToJson(temp))
    else: 
        print(getHexString(out))
    

def getHexString(messageBytes):
    if args.strip:
        array = messageBytes[2 : ]
    else:
        array = messageBytes

    return ''.join(format(x, '02x') for x in array)
    
async def processWhiteListInfo(whitelistInfo):
    jsontext = MessageToJson(whitelistInfo)
    jsonobj = json.loads(jsontext)

    for part in jsonobj["whitelistInfo"]["whitelistEntries"]:
        keyid_b64 = part['publicKeySHA1']
        keyid_bytes = base64.b64decode(keyid_b64)
        message = getWhitelistEntryMessage(keyid_bytes)
        messagebytes = message.SerializeToString()
        prefixbytes = getPrefix(len(messagebytes))
        sendmessage = prefixbytes + messagebytes
        log(1,"writing to 'To Vehicle' characteristic")
        await sendToVehicle(sendmessage)
        message = getSessionDataMessage(keyid_bytes)
        messagebytes = message.SerializeToString()
        prefixbytes = getPrefix(len(messagebytes))
        sendmessage = prefixbytes + messagebytes
        log(1,"writing to 'To Vehicle' characteristic")
        await sendToVehicle(sendmessage)

    
def getWhitelistEntryMessage(keybytes):
    keyId = VCSEC.KeyIdentifier(publicKeySHA1=keybytes)
    infoReq = VCSEC.InformationRequest(informationRequestType=VCSEC.INFORMATION_REQUEST_TYPE_GET_WHITELIST_ENTRY_INFO,keyId=keyId)
    unsignedMsg = VCSEC.UnsignedMessage(InformationRequest=infoReq) 
    toVcsecMsg = VCSEC.ToVCSECMessage(unsignedMessage=unsignedMsg)
    return toVcsecMsg

def getSessionDataMessage(keybytes):
    keyId = VCSEC.KeyIdentifier(publicKeySHA1=keybytes)
    infoReq = VCSEC.InformationRequest(informationRequestType=VCSEC.INFORMATION_REQUEST_TYPE_GET_SESSION_DATA,keyId=keyId)
    unsignedMsg = VCSEC.UnsignedMessage(InformationRequest=infoReq) 
    toVcsecMsg = VCSEC.ToVCSECMessage(unsignedMessage=unsignedMsg)
    return toVcsecMsg

async def notification_handler(sender, data):
    temp = VCSEC.FromVCSECMessage()
    temp.ParseFromString(data[2 : ])
    if (temp.HasField("whitelistInfo") and args.recursive):
        output(data)
        await processWhiteListInfo(temp)    
    elif temp.HasField("vehicleStatus"):
        # ignore
        print()
    elif temp.HasField("authenticationRequest"):
        # ignore
        print()
    else:
        output(data)

def log(level,message):
    if not args.quiet:
        if level<=args.verbose:
            if args.verbose>1:
                dt = datetime.now().isoformat()
                print(dt+" "+message)
            else:
                print(message)

if __name__ == "__main__":
    parser = argparse.ArgumentParser()

    # Required positional argument
    parser.add_argument("device", help="MAC address of the vehicle (e.g. 11:22:33:44:55:66)")

    # Optional positional argument
    parser.add_argument("--payload", help="hexstring of encoded message to vehicle", required=False)

    # Optional argument flag which defaults to False
    parser.add_argument("-q", "--quiet", action="store_true", default=False, help="supress output")

    # Optional argument flag which defaults to False
    parser.add_argument("-R", "--recursive", action="store_true", default=False, help="do recursive queries where it applies")

    # Optional argument flag which defaults to False
    parser.add_argument("-i", "--stdin", action="store_true", default=False, help="payload is provided as hexstring via stdin")

    # Optional argument flag which defaults to False
    parser.add_argument("-p", "--prefix", action="store_true",default=False, help="auto prefix message with length")

    # Optional argument flag which defaults to False
    parser.add_argument("-s", "--strip", action="store_true", default=False, help="strip length header from received messages")

    # Optional argument flag which defaults to False
    parser.add_argument("-t", "--template", default=False, help="use a payload template. valid values are PUBKEY, WHITELIST", required=False)

    # Optional argument flag which defaults to False
    parser.add_argument("-o", "--output", default="HEX", help="specifies the output format: BIN, HEX (default), JSON, TXT", required=False)

    # Optional argument flag which defaults to False
    parser.add_argument("--timeout", default="10", help="specifies the timeout in seconds", required=False)

    # Optional argument which requires a parameter (eg. -d test)
    parser.add_argument("-n", "--name", action="store", dest="name")

    # Optional verbosity counter (eg. -v, -vv, -vvv, etc.)
    parser.add_argument(
        "-v",
        "--verbose",
        action="count",
        default=0,
        help="Verbosity (-v, -vv, etc)")

    # Specify output of "--version"
    parser.add_argument(
        "--version",
        action="version",
        version="%(prog)s (version {version})".format(version=__version__))

    args = parser.parse_args()

    if args.quiet is False:
        ascii_banner = pyfiglet.figlet_format("tempara")
        print(ascii_banner)
        print("Author:  "+__author__)
        print("Version: "+__version__+"\n")

    loop = asyncio.get_event_loop()
    loop.run_until_complete(main(args))
