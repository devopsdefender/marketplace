import logging
import threading
import time
from datetime import datetime, timedelta, timezone

from models import Invoice, Rental, db
from payments import check_payment
from provisioner import deploy_workload

log = logging.getLogger(__name__)


def _provision_rental(rental, invoice):
    """Deploy a workload for a paid rental."""
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
        log.info("Provisioned rental %d as %s", rental.id, app_name)
    except Exception:
        log.exception("Failed to provision rental %d", rental.id)


def check_pending_payments():
    invoices = Invoice.query.filter_by(status="pending").all()
    for inv in invoices:
        if check_payment(inv.btc_address):
            inv.status = "paid"
            inv.paid_at = datetime.now(timezone.utc)
            if inv.rental and inv.rental.status == "awaiting_payment":
                _provision_rental(inv.rental, inv)
            db.session.commit()


def expire_rentals():
    now = datetime.now(timezone.utc)
    rentals = Rental.query.filter(
        Rental.status == "active",
        Rental.expires_at <= now,
    ).all()
    for rental in rentals:
        rental.status = "expired"
        log.info("Rental %d expired", rental.id)
    if rentals:
        db.session.commit()


def start_background_tasks(app):
    def _loop():
        with app.app_context():
            while True:
                try:
                    check_pending_payments()
                    expire_rentals()
                except Exception:
                    log.exception("Background task error")
                time.sleep(30)

    t = threading.Thread(target=_loop, daemon=True)
    t.start()
