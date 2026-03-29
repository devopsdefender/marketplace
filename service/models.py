from datetime import datetime, timezone

from flask_sqlalchemy import SQLAlchemy

db = SQLAlchemy()


class Invoice(db.Model):
    __tablename__ = "invoices"

    id = db.Column(db.Integer, primary_key=True)
    node_type = db.Column(db.String(32), nullable=False)
    hours = db.Column(db.Integer, nullable=False)
    btc_amount = db.Column(db.String(32), nullable=False)
    btc_address = db.Column(db.String(64), nullable=False)
    status = db.Column(db.String(16), nullable=False, default="pending")
    created_at = db.Column(db.DateTime, nullable=False, default=lambda: datetime.now(timezone.utc))
    paid_at = db.Column(db.DateTime, nullable=True)

    rental = db.relationship("Rental", back_populates="invoice", uselist=False)


class Rental(db.Model):
    __tablename__ = "rentals"

    id = db.Column(db.Integer, primary_key=True)
    invoice_id = db.Column(db.Integer, db.ForeignKey("invoices.id"), nullable=False)
    node_type = db.Column(db.String(32), nullable=False)
    app_name = db.Column(db.String(128), nullable=True)
    started_at = db.Column(db.DateTime, nullable=True)
    expires_at = db.Column(db.DateTime, nullable=True)
    status = db.Column(db.String(24), nullable=False, default="awaiting_payment")

    invoice = db.relationship("Invoice", back_populates="rental")
