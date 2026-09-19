"""Runs one server-SDK action against Arc, exactly as a Django backend would.

Invoked by the JavaScript harness, which asserts the effect on connected clients:

    python sdk_actions.py <action> [json-args]

Prints the SDK's return value as JSON. Configuration comes from ARC_HOST, ARC_PORT,
ARC_APP_ID, ARC_APP_KEY, ARC_APP_SECRET, ARC_MASTER_KEY.
"""
import base64
import json
import os
import sys

import pusher


def client():
    kwargs = dict(
        app_id=os.environ["ARC_APP_ID"],
        key=os.environ["ARC_APP_KEY"],
        secret=os.environ["ARC_APP_SECRET"],
        host=os.environ.get("ARC_HOST", "localhost"),
        port=int(os.environ.get("ARC_PORT", "4010")),
        ssl=False,
    )
    master = os.environ.get("ARC_MASTER_KEY")
    if master:
        kwargs["encryption_master_key_base64"] = master
    return pusher.Pusher(**kwargs)


def main():
    action = sys.argv[1]
    args = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
    p = client()

    try:
        if action == "trigger":
            result = p.trigger(args["channels"], args["event"], args["data"], args.get("socket_id"))
        elif action == "trigger_batch":
            result = p.trigger_batch(args["batch"])
        elif action == "channels_info":
            result = p.channels_info(args.get("prefix"), args.get("attributes", []))
        elif action == "channel_info":
            result = p.channel_info(args["channel"], args.get("attributes", []))
        elif action == "users_info":
            result = p.users_info(args["channel"])
        elif action == "terminate":
            result = p.terminate_user_connections(args["user_id"])
        elif action == "send_to_user":
            result = p.send_to_user(args["user_id"], args["event"], args["data"])
        elif action == "authorize":
            result = p.authenticate(args["channel"], args["socket_id"], args.get("custom_data"))
        elif action == "authenticate_user":
            result = p.authenticate_user(args["socket_id"], args["user_data"])
        elif action == "validate_webhook":
            body = base64.b64decode(args["body_b64"]).decode()
            result = p.validate_webhook(args["key"], args["signature"], body)
        elif action == "bad_secret":
            bad = pusher.Pusher(
                app_id=os.environ["ARC_APP_ID"], key=os.environ["ARC_APP_KEY"], secret="0" * 20,
                host=os.environ.get("ARC_HOST", "localhost"), port=int(os.environ.get("ARC_PORT", "4010")), ssl=False,
            )
            result = bad.trigger("x", "e", {})
        else:
            raise SystemExit(f"unknown action {action}")
    except pusher.errors.PusherError as error:
        print(json.dumps({"error": type(error).__name__, "message": str(error)}))
        return

    print(json.dumps(result if result is not None else {}))


if __name__ == "__main__":
    main()
