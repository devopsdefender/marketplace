from datetime import datetime, timedelta, timezone
from decimal import Decimal

from flask import Blueprint, jsonify, request

from config import NODE_TYPES
from models import Invoice, Rental, db
from payments import generate_address
from provisioner import deploy_workload

api = Blueprint("api", __name__)


@api.route("/health")
def health():
    return jsonify({"status": "ok"})


@api.route("/api/capacity")
def list_capacity():
    return jsonify(NODE_TYPES)


@api.route("/api/rentals", methods=["POST"])
def create_rental():
    data = request.get_json(force=True)
    node_type = data.get("node_type")
    hours = data.get("hours")

    if node_type not in NODE_TYPES:
        return jsonify({"error": f"unknown node_type, choose from: {list(NODE_TYPES)}"}), 400
    if not isinstance(hours, (int, float)) or hours <= 0:
        return jsonify({"error": "hours must be a positive number"}), 400

    hours = int(hours)
    spec = NODE_TYPES[node_type]
    btc_amount = str(Decimal(spec["btc_per_hour"]) * hours)

    invoice = Invoice(
        node_type=node_type,
        hours=hours,
        btc_amount=btc_amount,
        btc_address=generate_address(),
    )
    db.session.add(invoice)
    db.session.flush()

    rental = Rental(
        invoice_id=invoice.id,
        node_type=node_type,
    )
    db.session.add(rental)
    db.session.commit()

    return jsonify({
        "rental_id": rental.id,
        "invoice": {
            "id": invoice.id,
            "btc_address": invoice.btc_address,
            "btc_amount": invoice.btc_amount,
            "status": invoice.status,
        },
    }), 201


@api.route("/api/rentals/<int:rental_id>")
def get_rental(rental_id):
    rental = db.session.get(Rental, rental_id)
    if not rental:
        return jsonify({"error": "not found"}), 404

    return jsonify({
        "id": rental.id,
        "node_type": rental.node_type,
        "status": rental.status,
        "app_name": rental.app_name,
        "started_at": rental.started_at.isoformat() if rental.started_at else None,
        "expires_at": rental.expires_at.isoformat() if rental.expires_at else None,
        "invoice": {
            "id": rental.invoice.id,
            "btc_address": rental.invoice.btc_address,
            "btc_amount": rental.invoice.btc_amount,
            "status": rental.invoice.status,
        },
    })


@api.route("/api/invoices/<int:invoice_id>")
def get_invoice(invoice_id):
    invoice = db.session.get(Invoice, invoice_id)
    if not invoice:
        return jsonify({"error": "not found"}), 404

    return jsonify({
        "id": invoice.id,
        "node_type": invoice.node_type,
        "hours": invoice.hours,
        "btc_amount": invoice.btc_amount,
        "btc_address": invoice.btc_address,
        "status": invoice.status,
        "created_at": invoice.created_at.isoformat(),
        "paid_at": invoice.paid_at.isoformat() if invoice.paid_at else None,
    })


@api.route("/api/invoices/<int:invoice_id>/simulate-payment", methods=["POST"])
def simulate_payment(invoice_id):
    invoice = db.session.get(Invoice, invoice_id)
    if not invoice:
        return jsonify({"error": "not found"}), 404
    if invoice.status != "pending":
        return jsonify({"error": f"invoice is already {invoice.status}"}), 400

    invoice.status = "paid"
    invoice.paid_at = datetime.now(timezone.utc)

    rental = invoice.rental
    if rental and rental.status == "awaiting_payment":
        app_name = f"rental-{rental.id}-{rental.node_type}"
        try:
            deploy_workload(
                app_name=app_name,
                image="ghcr.io/openclaw/openclaw:latest",
                ports=["8080:3000"],
            )
            rental.app_name = app_name
            rental.status = "active"
            rental.started_at = datetime.now(timezone.utc)
            rental.expires_at = rental.started_at + timedelta(hours=invoice.hours)
        except Exception as e:
            rental.status = "provision_failed"
            db.session.commit()
            return jsonify({"error": f"payment accepted but provisioning failed: {e}"}), 502

    db.session.commit()

    return jsonify({
        "invoice": {"id": invoice.id, "status": invoice.status},
        "rental": {"id": rental.id, "status": rental.status} if rental else None,
    })
