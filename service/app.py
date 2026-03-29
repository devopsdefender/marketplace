import os

from flask import Flask

from config import DATABASE_PATH, SERVICE_PORT
from models import db
from routes import api
from scheduler import start_background_tasks


def create_app():
    app = Flask(__name__)

    os.makedirs(os.path.dirname(DATABASE_PATH), exist_ok=True)
    app.config["SQLALCHEMY_DATABASE_URI"] = f"sqlite:///{DATABASE_PATH}"
    app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False

    db.init_app(app)
    app.register_blueprint(api)

    with app.app_context():
        db.create_all()

    start_background_tasks(app)
    return app


if __name__ == "__main__":
    app = create_app()
    app.run(host="0.0.0.0", port=SERVICE_PORT)
